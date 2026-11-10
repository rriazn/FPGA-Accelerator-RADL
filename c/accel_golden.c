/* Runs one conv layer of ResNet-8 on the accelerator and compares the int32 accumulators with the golden vectors
 *
 *   accel_golden <export_dir> <layer> [frame] [--regs <addr> --mem <addr>:<size>]
 *       layer = stem b1c1 b1c2 b2c1 b2c2 b2sc b3c1 b3c2 b3sc, frame = golden frame directory (default f000)
 *       without options it runs on the stand-in (accel_sim.c), which also checks the golden files against the layouts
 *
 * reads <export_dir>/layers.txt, <layer>_w.mem, <layer>_b.mem and <export_dir>/golden/<frame>/<layer>_in.mem and
 * <layer>_acc.mem, the same files the VHDL testbenches use (hardware layout: input blocked with 16 lanes, lanes = 1 for the stem)
 * the golden directory is not part of the board package (make package), copy golden/<frame> to the board by hand
 * exit code 1 if any accumulator differs, 2 on bad input
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "accel.h"
#include "platform_cli.h"

typedef struct {
    const char *name;
    int h;        /* input height and width */
    int in_lanes; /* 1 for the raw frame, 16 for the feature maps */
} geom_t;

/* the input sizes of the layers, as in vhdl/tests/integration/tb_conv_accel_top.vhd */
static const geom_t GEOM[] = {
    {"stem", 112, 1}, {"b1c1", 56, 16}, {"b1c2", 56, 16}, {"b2c1", 56, 16}, {"b2c2", 28, 16},
    {"b2sc", 56, 16}, {"b3c1", 28, 16}, {"b3c2", 14, 16}, {"b3sc", 28, 16},
};

static void die(const char *msg, const char *arg) {
    fprintf(stderr, "error: %s %s\n", msg, arg);
    exit(2);
}

/* .mem file: one hex value per line, two's complement, the number of values is checked against n */
static void read_mem(const char *path, int bits, size_t n, void *out) {
    FILE *f = fopen(path, "r");
    unsigned v;
    if (!f) die("cannot open", path);
    for (size_t i = 0; i < n; i++) {
        if (fscanf(f, "%x", &v) != 1) die("too few values in", path);
        if (bits == 8) ((int8_t *)out)[i] = (int8_t)(uint8_t)v;
        else ((int32_t *)out)[i] = (int32_t)(uint32_t)v;
    }
    if (fscanf(f, "%x", &v) == 1) die("too many values in", path);
    fclose(f);
}

int main(int argc, char **argv) {
    const char *backend;
    platform_t p = platform_open(&argc, argv, &backend);
    if (argc < 3 || argc > 4) {
        fprintf(stderr, "usage: %s <export_dir> <layer> [frame] [--regs <addr> --mem <addr>:<size>]\n", argv[0]);
        return 2;
    }
    const char *dir = argv[1], *layer = argv[2], *frame = argc > 3 ? argv[3] : "f000";

    const geom_t *g = NULL;
    for (unsigned i = 0; i < sizeof GEOM / sizeof GEOM[0]; i++)
        if (!strcmp(GEOM[i].name, layer)) g = &GEOM[i];
    if (!g) die("unknown layer", layer);

    char path[512], line[256];
    snprintf(path, sizeof path, "%s/layers.txt", dir);
    FILE *f = fopen(path, "r");
    if (!f) die("cannot open", path);
    int K = 0, C = 0, FY = 0, FX = 0, stride = 0, pad = 0;
    while (fgets(line, sizeof line, f)) {
        char name[16];
        int m0, shift;
        if (line[0] != '#' && sscanf(line, "%15s %d %d %d %d %d %d %d %d", name, &K, &C, &FY, &FX, &stride, &pad, &m0, &shift) == 9 &&
            !strcmp(name, layer))
            break;
        K = 0;
    }
    fclose(f);
    if (!K) die("layer not in layers.txt:", layer);
    if (C % g->in_lanes || K % ACCEL_LANES) die("padded channels are not supported:", layer);

    int H = g->h, W = g->h;
    int OH = accel_out_dim(H, FY, stride, pad), OW = accel_out_dim(W, FX, stride, pad);
    size_t n_in = (size_t)C * H * W, n_w = (size_t)K * C * FY * FX, n_out = (size_t)K * OH * OW;

    int8_t *x = malloc(n_in), *w = malloc(n_w);
    int32_t *b = malloc(4 * (size_t)K), *exp = malloc(4 * n_out), *got = malloc(4 * n_out);
    snprintf(path, sizeof path, "%s/%s_w.mem", dir, layer);
    read_mem(path, 8, n_w, w);
    snprintf(path, sizeof path, "%s/%s_b.mem", dir, layer);
    read_mem(path, 32, K, b);
    snprintf(path, sizeof path, "%s/golden/%s/%s_in.mem", dir, frame, layer);
    read_mem(path, 8, n_in, x);
    snprintf(path, sizeof path, "%s/golden/%s/%s_acc.mem", dir, frame, layer);
    read_mem(path, 32, n_out, exp);

    dma_buf_t dx = p.alloc(p.ctx, n_in), dw = p.alloc(p.ctx, n_w), db = p.alloc(p.ctx, 4 * (size_t)K), dout = p.alloc(p.ctx, 4 * n_out);
    dma_copy(dx.virt, x, n_in);
    dma_copy(dw.virt, w, n_w);
    dma_copy(db.virt, b, 4 * (size_t)K);
    memset(got, 0x5A, 4 * n_out);
    dma_copy(dout.virt, got, 4 * n_out); /* an unwritten word then shows up as a mismatch */

    accel_layer_t a = {C, K, H, W, FY, FX, stride, pad, g->in_lanes, ACCEL_LANES, &dx, &dw, &db, &dout};
    uint32_t cycles = 0;
    int rc = accel_run(&p, &a, &cycles);
    if (rc != ACCEL_OK) {
        fprintf(stderr, "error: accelerator failed on %s (code %d)\n", layer, rc);
        platform_close();
        return 2;
    }
    dma_copy(got, dout.virt, 4 * n_out);

    size_t bad = 0;
    for (size_t i = 0; i < n_out; i++)
        if (got[i] != exp[i] && bad++ < 5) printf("  word %zu: got %d, expected %d\n", i, got[i], exp[i]);
    printf("%s frame %s on %s: %zu results, %zu differ, CYCLES %u: %s\n", layer, frame, backend, n_out, bad, cycles,
           bad ? "FAIL" : "bit-exact");
    platform_close();
    return bad != 0;
}
