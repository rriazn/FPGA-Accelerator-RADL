/* ResNet-8 inference with the conv layers on the accelerator and the rest on the ARM (D2)
 * the accelerator returns the int32 accumulator, the ARM does requant, ReLU, residual add, global pool and FC
 * without options the accelerator is the software stand-in of accel_sim.c, so this checks the driver, the layouts and
 * the ARM side; with --regs and --mem it runs on the board (board_platform.h)
 * the run fails if any logit differs from test_logits.bin, like camus_naive
 *
 *   camus_accel <export_dir> [frames] [--regs <addr> --mem <addr>:<size>]
 *       frames = use only the first N test frames (default all)
 *       --regs = physical address of the AXI-Lite registers, --mem = reserved DDR range for the DMA buffers
 *
 * activations stay in the blocked layout [C/16][H][W][16] between the layers, which is correct because requant, ReLU
 * and the residual add are elementwise, only the global pool needs the index mapping; the raw frame is lanes = 1
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "accel.h"
#include "platform_cli.h"

#define DEADLINE_MS 33.0
#define IN_H 112
#define IN_W 112
#define N_CLASSES 2
#define MAX_ACT (16 * 56 * 56) /* largest feature map: stem / block 1 output */
#define MAX_LAYERS 16

typedef struct {
    char name[16];
    int K, C, FY, FX, stride, pad, shift;
    int32_t m0;
    int8_t *w;
    int32_t *b;
    dma_buf_t dw, db; /* weights and bias in DMA memory, only for the layers the accelerator runs */
} layer_t;

typedef struct {
    const layer_t *stem, *c1[3], *c2[3], *sc[3], *skip, *fc; /* sc[0] is NULL: block 1 has an identity shortcut */
} resnet8_t;

typedef struct {
    dma_buf_t x, a, h, acc1, acc2;
} work_t;

static unsigned long g_calls;               /* accelerator calls so far */
static unsigned long long g_cycles;         /* sum of the CYCLES register of those calls */

static void die(const char *msg, const char *arg) {
    fprintf(stderr, "error: %s %s\n", msg, arg);
    exit(2);
}

static void *read_file(const char *dir, const char *name, size_t *size) {
    char path[512];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "rb");
    if (!f) die("cannot open", path);
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    void *buf = malloc(n > 0 ? n : 1);
    if (!buf || fread(buf, 1, n, f) != (size_t)n) die("cannot read", path);
    fclose(f);
    *size = n;
    return buf;
}

/* .mem file: one hex value per line, two's complement; bits = 8 or 32 */
static void read_mem(const char *dir, const char *name, int bits, size_t n, void *out) {
    char path[512];
    unsigned v;
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "r");
    if (!f) die("cannot open", path);
    for (size_t i = 0; i < n; i++) {
        if (fscanf(f, "%x", &v) != 1) die("too few values in", path);
        if (bits == 8) ((int8_t *)out)[i] = (int8_t)(uint8_t)v;
        else ((int32_t *)out)[i] = (int32_t)(uint32_t)v;
    }
    if (fscanf(f, "%x", &v) == 1) die("too many values in", path);
    fclose(f);
}

static int load_layers(const char *dir, layer_t *L) {
    size_t size;
    char *txt = read_file(dir, "layers.txt", &size), *line, *save;
    char *buf = malloc(size + 1);
    memcpy(buf, txt, size);
    buf[size] = 0;
    free(txt);
    int n = 0;
    for (line = strtok_r(buf, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        if (line[0] == '#' || !line[0]) continue;
        if (n == MAX_LAYERS) die("too many layers in", "layers.txt");
        layer_t *l = &L[n++];
        if (sscanf(line, "%15s %d %d %d %d %d %d %d %d", l->name, &l->K, &l->C, &l->FY, &l->FX,
                   &l->stride, &l->pad, &l->m0, &l->shift) != 9) die("bad row in layers.txt:", line);
        if (l->K == 0) continue; /* no weights (identity-shortcut multiplier) */
        char file[64];
        size_t nw = (size_t)l->K * l->C * l->FY * l->FX;
        l->w = malloc(nw);
        l->b = malloc(l->K * sizeof(int32_t));
        snprintf(file, sizeof file, "%s_w.mem", l->name);
        read_mem(dir, file, 8, nw, l->w);
        snprintf(file, sizeof file, "%s_b.mem", l->name);
        read_mem(dir, file, 32, l->K, l->b);
    }
    free(buf);
    return n;
}

static layer_t *get(layer_t *L, int n, const char *name) {
    for (int i = 0; i < n; i++)
        if (!strcmp(L[i].name, name)) return &L[i];
    die("layer missing in layers.txt:", name);
    return NULL;
}

/* weights and bias of a conv layer go into DMA memory once, the layout is the plain export layout */
static void upload(const platform_t *p, layer_t *l) {
    l->dw = p->alloc(p->ctx, (size_t)l->K * l->C * l->FY * l->FX);
    l->db = p->alloc(p->ctx, l->K * sizeof(int32_t));
    dma_copy(l->dw.virt, l->w, l->dw.size);
    dma_copy(l->db.virt, l->b, l->db.size);
}

static int32_t requant(int32_t acc, int32_t m0, int shift) {
    return (int32_t)(((int64_t)acc * m0 + ((int64_t)1 << (shift - 1))) >> shift);
}

static int8_t relu8(int32_t v) { return v < 0 ? 0 : v > 127 ? 127 : (int8_t)v; }

/* one conv layer on the accelerator, the result is the int32 accumulator in out, blocked with 16 lanes */
static void conv(const platform_t *p, const layer_t *l, const dma_buf_t *in, int in_lanes, int H, int W,
                 const dma_buf_t *out, int *OH, int *OW) {
    if (l->C % in_lanes || l->K % ACCEL_LANES) die("padded channels are not supported:", l->name);
    accel_layer_t a = {l->C, l->K, H, W, l->FY, l->FX, l->stride, l->pad, in_lanes, ACCEL_LANES, in, &l->dw, &l->db, out};
    uint32_t cycles;
    int rc = accel_run(p, &a, &cycles);
    if (rc != ACCEL_OK) {
        fprintf(stderr, "error: accelerator failed on %s (code %d)\n", l->name, rc);
        exit(2);
    }
    g_calls++;
    g_cycles += cycles;
    *OH = accel_out_dim(H, l->FY, l->stride, l->pad);
    *OW = accel_out_dim(W, l->FX, l->stride, l->pad);
    /* requant of the accumulator on the ARM (D2), in place, no clipping, the branch is clipped after the add */
    int32_t *y = out->virt;
    for (int i = 0; i < l->K * *OH * *OW; i++) y[i] = requant(y[i], l->m0, l->shift);
}

static void infer(const platform_t *p, const resnet8_t *n, const int8_t *frame, work_t *w, int32_t logits[N_CLASSES]) {
    int8_t *a = w->a.virt, *h = w->h.virt;
    int32_t *r2 = w->acc1.virt, *rs = w->acc2.virt;
    int H = IN_H, W = IN_W, oh, ow, oh2, ow2;

    dma_copy(w->x.virt, frame, IN_H * IN_W);
    conv(p, n->stem, &w->x, 1, H, W, &w->acc1, &oh, &ow);
    for (int i = 0; i < n->stem->K * oh * ow; i++) a[i] = relu8(r2[i]);
    H = oh;
    W = ow;
    for (int b = 0; b < 3; b++) {
        conv(p, n->c1[b], &w->a, ACCEL_LANES, H, W, &w->acc1, &oh, &ow);
        for (int i = 0; i < n->c1[b]->K * oh * ow; i++) h[i] = relu8(r2[i]);
        conv(p, n->c2[b], &w->h, ACCEL_LANES, oh, ow, &w->acc1, &oh, &ow);
        int n_out = n->c2[b]->K * oh * ow;
        if (n->sc[b]) {
            conv(p, n->sc[b], &w->a, ACCEL_LANES, H, W, &w->acc2, &oh2, &ow2);
        } else { /* identity shortcut, rescaled to the block output scale */
            for (int i = 0; i < n_out; i++) rs[i] = requant(a[i], n->skip->m0, n->skip->shift);
        }
        for (int i = 0; i < n_out; i++) a[i] = relu8(r2[i] + rs[i]);
        H = oh;
        W = ow;
    }
    /* global pool as a sum (the 1/(H*W) is folded into fc bias), then fc; the only step that needs the layout */
    int32_t pooled[64];
    for (int c = 0; c < n->fc->C; c++) {
        int32_t s = 0;
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) s += a[accel_elem(c, y, x, H, W, ACCEL_LANES)];
        pooled[c] = s;
    }
    for (int k = 0; k < n->fc->K; k++) {
        int32_t acc = n->fc->b[k];
        for (int c = 0; c < n->fc->C; c++) acc += n->fc->w[k * n->fc->C + c] * pooled[c];
        logits[k] = acc;
    }
}

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
    const char *backend;
    platform_t p = platform_open(&argc, argv, &backend);
    if (argc < 2) {
        fprintf(stderr, "usage: %s <export_dir> [frames] [--regs <addr> --mem <addr>:<size>]\n", argv[0]);
        return 2;
    }
    const char *dir = argv[1];
    int frames = argc > 2 ? atoi(argv[2]) : 0;
    if (argc > 2 && frames < 1) die("bad frames:", argv[2]);

    layer_t L[MAX_LAYERS] = {0};
    int nl = load_layers(dir, L);
    resnet8_t net = {0};
    char name[16];
    net.stem = get(L, nl, "stem");
    net.skip = get(L, nl, "b1skip");
    net.fc = get(L, nl, "fc");
    for (int b = 0; b < 3; b++) {
        snprintf(name, sizeof name, "b%dc1", b + 1);
        net.c1[b] = get(L, nl, name);
        snprintf(name, sizeof name, "b%dc2", b + 1);
        net.c2[b] = get(L, nl, name);
        if (b > 0) {
            snprintf(name, sizeof name, "b%dsc", b + 1);
            net.sc[b] = get(L, nl, name);
        }
    }

    for (int i = 0; i < nl; i++)
        if (L[i].K && strcmp(L[i].name, "fc")) upload(&p, &L[i]);
    work_t work = {0};
    work.x = p.alloc(p.ctx, IN_H * IN_W);
    work.a = p.alloc(p.ctx, MAX_ACT);
    work.h = p.alloc(p.ctx, MAX_ACT);
    work.acc1 = p.alloc(p.ctx, MAX_ACT * sizeof(int32_t));
    work.acc2 = p.alloc(p.ctx, MAX_ACT * sizeof(int32_t));

    size_t sx, sy, sl;
    int8_t *tx = read_file(dir, "test_x.bin", &sx);
    uint8_t *ty = read_file(dir, "test_y.bin", &sy);
    int32_t *tl = read_file(dir, "test_logits.bin", &sl); /* little-endian int32; the board and host are LE */
    size_t N = sy;
    if (sx != N * IN_H * IN_W || sl != N * N_CLASSES * sizeof(int32_t)) die("inconsistent test files in", dir);
    if (frames > 0 && (size_t)frames < N) N = frames;

    size_t correct = 0, mismatches = 0, over = 0;
    double sum = 0, tmin = 1e30, tmax = 0;
    for (size_t i = 0; i < N; i++) {
        int32_t logits[N_CLASSES];
        double t0 = now_ms();
        infer(&p, &net, tx + i * IN_H * IN_W, &work, logits);
        double dt = now_ms() - t0;
        sum += dt;
        if (dt < tmin) tmin = dt;
        if (dt > tmax) tmax = dt;
        if (dt > DEADLINE_MS) over++;
        correct += (logits[1] > logits[0]) == ty[i];
        mismatches += memcmp(logits, tl + i * N_CLASSES, sizeof logits) != 0;
    }
    printf("frames %zu, accelerator: %s\n", N, backend);
    printf("accuracy %.4f\n", (double)correct / N);
    printf("bit-exact vs test_logits.bin: %s (%zu of %zu frames differ)\n", mismatches ? "NO" : "yes", mismatches, N);
    printf("latency ms: mean %.3f  min %.3f  max %.3f  (whole frame, ARM steps included)\n", sum / N, tmin, tmax);
    printf("frames over %.0f ms deadline: %zu\n", DEADLINE_MS, over);
    printf("accelerator calls %lu (%.1f per frame), CYCLES %llu (%.0f per frame%s)\n", g_calls, (double)g_calls / N, g_cycles,
           (double)g_cycles / N, strcmp(backend, "board") ? ", stand-in: the MAC count" : ", clocks of the accelerator");
    platform_close();
    return mismatches != 0;
}
