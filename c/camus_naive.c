/* Naive int8 ResNet-8 inference for CAMUS 2CH vs 4CH: the RADL baseline.
 * Plain C11, libc only, one thread, straightforward loops (no tiling, SIMD or reordering).
 * Weights, layer table and test set are read at runtime from the Python export directory.
 * Bit-exact to python/quantize.py; the run fails if any logit differs from test_logits.bin.
 *
 *   camus_naive <export_dir> [reps]     reps = passes over the test set (default 1; use more for power runs)
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define IN_H 112
#define IN_W 112
#define N_CLASSES 2
#define MAX_ACT (16 * 56 * 56) /* largest feature map: stem / block 1 output */
#define MAX_LAYERS 16
#define DEADLINE_MS 33.0

typedef struct {
    char name[16];
    int K, C, FY, FX, stride, pad, shift;
    int32_t m0;
    int8_t *w;
    int32_t *b;
} layer_t;

typedef struct {
    const layer_t *stem, *c1[3], *c2[3], *sc[3], *skip, *fc; /* sc[0] is NULL: block 1 has an identity shortcut */
} resnet8_t;

typedef struct {
    int8_t a[MAX_ACT], h[MAX_ACT];
    int32_t r2[MAX_ACT], rs[MAX_ACT];
} work_t;

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

static const layer_t *get(const layer_t *L, int n, const char *name) {
    for (int i = 0; i < n; i++)
        if (!strcmp(L[i].name, name)) return &L[i];
    die("layer missing in layers.txt:", name);
    return NULL;
}

/* Arithmetic right shift of a negative int64 is implementation-defined in C; gcc/clang/MSVC all do it. */
static int32_t requant(int32_t acc, int32_t m0, int shift) {
    return (int32_t)(((int64_t)acc * m0 + ((int64_t)1 << (shift - 1))) >> shift);
}

/* y[k][oy][ox] = requant(b[k] + sum x[c][iy][ix] * w[k][c][fy][fx]), zero padding, no clipping */
static void conv_rq(const layer_t *L, const int8_t *x, int H, int W, int32_t *y, int *OH, int *OW) {
    int oh = (H + 2 * L->pad - L->FY) / L->stride + 1;
    int ow = (W + 2 * L->pad - L->FX) / L->stride + 1;
    for (int k = 0; k < L->K; k++)
        for (int oy = 0; oy < oh; oy++)
            for (int ox = 0; ox < ow; ox++) {
                int32_t acc = L->b[k];
                for (int c = 0; c < L->C; c++)
                    for (int fy = 0; fy < L->FY; fy++)
                        for (int fx = 0; fx < L->FX; fx++) {
                            int iy = oy * L->stride - L->pad + fy;
                            int ix = ox * L->stride - L->pad + fx;
                            if (iy < 0 || iy >= H || ix < 0 || ix >= W) continue;
                            acc += x[(c * H + iy) * W + ix] * L->w[((k * L->C + c) * L->FY + fy) * L->FX + fx];
                        }
                y[(k * oh + oy) * ow + ox] = requant(acc, L->m0, L->shift);
            }
    *OH = oh;
    *OW = ow;
}

static int8_t relu8(int32_t v) { return v < 0 ? 0 : v > 127 ? 127 : (int8_t)v; }

static void infer(const resnet8_t *n, const int8_t *x, work_t *w, int32_t logits[N_CLASSES]) {
    int H = IN_H, W = IN_W, oh, ow, oh2, ow2;
    conv_rq(n->stem, x, H, W, w->r2, &oh, &ow);
    for (int i = 0; i < n->stem->K * oh * ow; i++) w->a[i] = relu8(w->r2[i]);
    H = oh;
    W = ow;
    for (int b = 0; b < 3; b++) {
        conv_rq(n->c1[b], w->a, H, W, w->r2, &oh, &ow);
        for (int i = 0; i < n->c1[b]->K * oh * ow; i++) w->h[i] = relu8(w->r2[i]);
        conv_rq(n->c2[b], w->h, oh, ow, w->r2, &oh, &ow);
        int n_out = n->c2[b]->K * oh * ow;
        if (n->sc[b]) {
            conv_rq(n->sc[b], w->a, H, W, w->rs, &oh2, &ow2);
        } else { /* identity shortcut, rescaled to the block output scale */
            for (int i = 0; i < n_out; i++) w->rs[i] = requant(w->a[i], n->skip->m0, n->skip->shift);
        }
        for (int i = 0; i < n_out; i++) w->a[i] = relu8(w->r2[i] + w->rs[i]);
        H = oh;
        W = ow;
    }
    /* global pool as a sum (the 1/(H*W) is folded into fc bias), then fc */
    int32_t pooled[64];
    for (int c = 0; c < n->fc->C; c++) {
        int32_t s = 0;
        for (int i = 0; i < H * W; i++) s += w->a[c * H * W + i];
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
    timespec_get(&ts, TIME_UTC);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <export_dir> [reps]\n", argv[0]);
        return 2;
    }
    const char *dir = argv[1];
    int reps = argc > 2 ? atoi(argv[2]) : 1;
    if (reps < 1) die("bad reps:", argv[2]);

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

    size_t sx, sy, sl;
    int8_t *tx = read_file(dir, "test_x.bin", &sx);
    uint8_t *ty = read_file(dir, "test_y.bin", &sy);
    int32_t *tl = read_file(dir, "test_logits.bin", &sl); /* little-endian int32; the board and host are LE */
    size_t N = sy;
    if (sx != N * IN_H * IN_W || sl != N * N_CLASSES * sizeof(int32_t)) die("inconsistent test files in", dir);

    static work_t work;
    size_t correct = 0, mismatches = 0, over = 0;
    double sum = 0, tmin = 1e30, tmax = 0, t_start = now_ms();
    for (int r = 0; r < reps; r++)
        for (size_t i = 0; i < N; i++) {
            int32_t logits[N_CLASSES];
            double t0 = now_ms();
            infer(&net, tx + i * IN_H * IN_W, &work, logits);
            double dt = now_ms() - t0;
            sum += dt;
            if (dt < tmin) tmin = dt;
            if (dt > tmax) tmax = dt;
            if (dt > DEADLINE_MS) over++;
            correct += (logits[1] > logits[0]) == ty[i];
            mismatches += memcmp(logits, tl + i * N_CLASSES, sizeof logits) != 0;
        }
    double total = now_ms() - t_start;
    size_t runs = (size_t)reps * N;
    printf("frames %zu (%d x %zu)\n", runs, reps, N);
    printf("accuracy %.4f\n", (double)correct / runs);
    printf("bit-exact vs test_logits.bin: %s (%zu of %zu frames differ)\n", mismatches ? "NO" : "yes", mismatches, runs);
    printf("latency ms: mean %.3f  min %.3f  max %.3f\n", sum / runs, tmin, tmax);
    printf("frames over %.0f ms deadline: %zu\n", DEADLINE_MS, over);
    printf("wall time %.1f s, %.1f frames/s\n", total / 1e3, runs / (total / 1e3));
    return mismatches != 0;
}
