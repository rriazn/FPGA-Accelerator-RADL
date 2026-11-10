/* Bring-up test of the conv accelerator: run it first on a new board setup, it needs no export files
 *
 *   accel_probe [--regs <addr> --mem <addr>:<size>]     without options it runs on the stand-in (accel_sim.c)
 *
 * 1. STATUS must show not busy
 * 2. layer registers: write a pattern, read it back with the bit masks of the hardware, CTRL reads 0, unmapped reads 0
 * 3. the five small layers of the VHDL testbench (tiny_a .. tiny_e: lanes 1 and 16, padded channels, stride, 1x1)
 *    with random data against a reference conv, junk in the padding lanes of the input, the padding lanes and the
 *    bytes after the output must stay untouched
 * exit code 1 if anything fails
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "accel.h"
#include "accel_regs.h"
#include "platform_cli.h"

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("  FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)

static uint32_t g_rng = 12345;
static uint32_t rnd(void) {
    g_rng ^= g_rng << 13;
    g_rng ^= g_rng >> 17;
    g_rng ^= g_rng << 5;
    return g_rng;
}

typedef struct {
    const char *name;
    int k, c, h, w, fy, fx, stride, pad, inl, outl;
} shape_t;

/* the shapes of vhdl/tests/integration/tb_conv_accel_top.vhd */
static const shape_t SHAPES[] = {
    {"tiny_a", 5, 3, 7, 6, 3, 3, 1, 1, 1, 16},
    {"tiny_b", 18, 20, 6, 5, 3, 3, 2, 1, 16, 16},
    {"tiny_c", 3, 17, 5, 7, 1, 1, 2, 0, 16, 1},
    {"tiny_d", 2, 1, 4, 4, 3, 3, 1, 1, 1, 1},
    {"tiny_e", 4, 1, 5, 5, 1, 1, 1, 0, 1, 1},
};

#define FILL 0x5A
#define MARGIN 64

static void test_status(const platform_t *p) {
    uint32_t st = p->reg_read(p->ctx, ACCEL_REG_STATUS);
    printf("STATUS 0x%x (busy %u, done %u, error %u)\n", st, st & 1, (st >> 1) & 1, (st >> 2) & 1);
    CHECK(!(st & ACCEL_STATUS_BUSY), "the accelerator is busy before any start");
}

static void test_registers(const platform_t *p) {
    static const struct { uint32_t off, mask; const char *name; } REGS[] = {
        {ACCEL_REG_C, 0xFFFF, "C"}, {ACCEL_REG_K, 0xFFFF, "K"}, {ACCEL_REG_H, 0xFFFF, "H"}, {ACCEL_REG_W, 0xFFFF, "W"},
        {ACCEL_REG_FY, 0x7, "FY"}, {ACCEL_REG_FX, 0x7, "FX"}, {ACCEL_REG_STRIDE, 0x7, "STRIDE"}, {ACCEL_REG_PAD, 0x7, "PAD"},
        {ACCEL_REG_IN_LANES, 0x1F, "IN_LANES"}, {ACCEL_REG_OUT_LANES, 0x1F, "OUT_LANES"},
        {ACCEL_REG_IN_BASE, 0xFFFFFFFFu, "IN_BASE"}, {ACCEL_REG_W_BASE, 0xFFFFFFFFu, "W_BASE"},
        {ACCEL_REG_B_BASE, 0xFFFFFFFFu, "B_BASE"}, {ACCEL_REG_OUT_BASE, 0xFFFFFFFFu, "OUT_BASE"},
    };
    printf("layer registers\n");
    for (unsigned i = 0; i < sizeof REGS / sizeof REGS[0]; i++) {
        uint32_t v = 0xA5C3F00Fu + 0x01010101u * i;
        p->reg_write(p->ctx, REGS[i].off, v);
        uint32_t r = p->reg_read(p->ctx, REGS[i].off);
        CHECK(r == (v & REGS[i].mask), "%s: wrote 0x%08x, read 0x%08x, expected 0x%08x", REGS[i].name, v, r, v & REGS[i].mask);
    }
    CHECK(p->reg_read(p->ctx, ACCEL_REG_CTRL) == 0, "CTRL does not read 0");
    CHECK(p->reg_read(p->ctx, 0x44) == 0, "unmapped 0x44 does not read 0");
    CHECK(p->reg_read(p->ctx, 0x50) == 0, "unmapped 0x50 does not read 0");
}

static void fill(const dma_buf_t *b, uint8_t v) {
    uint8_t *tmp = malloc(b->size);
    memset(tmp, v, b->size);
    dma_copy(b->virt, tmp, b->size);
    free(tmp);
}

static void test_layer(const platform_t *p, const shape_t *s) {
    int oh = accel_out_dim(s->h, s->fy, s->stride, s->pad), ow = accel_out_dim(s->w, s->fx, s->stride, s->pad);
    size_t n_in = (size_t)((s->c + s->inl - 1) / s->inl) * s->h * s->w * s->inl;
    size_t n_w = (size_t)s->k * s->c * s->fy * s->fx;
    size_t n_out = (size_t)((s->k + s->outl - 1) / s->outl) * oh * ow * s->outl;

    int8_t *x = malloc(n_in), *w = malloc(n_w);
    int32_t *b = malloc(4 * s->k);
    for (size_t i = 0; i < n_in; i++) x[i] = (int8_t)rnd(); /* the padding lanes get junk too */
    for (size_t i = 0; i < n_w; i++) w[i] = (int8_t)rnd();
    for (int i = 0; i < s->k; i++) b[i] = (int32_t)(rnd() % 200001) - 100000;

    dma_buf_t dx = p->alloc(p->ctx, n_in), dw = p->alloc(p->ctx, n_w), db = p->alloc(p->ctx, 4 * s->k);
    dma_buf_t dout = p->alloc(p->ctx, 4 * n_out + MARGIN);
    dma_copy(dx.virt, x, n_in);
    dma_copy(dw.virt, w, n_w);
    dma_copy(db.virt, b, 4 * s->k);
    fill(&dout, FILL);

    dma_buf_t out_exact = dout;
    out_exact.size = 4 * n_out;
    accel_layer_t a = {s->c, s->k, s->h, s->w, s->fy, s->fx, s->stride, s->pad, s->inl, s->outl, &dx, &dw, &db, &out_exact};
    uint32_t cycles = 0;
    int rc = accel_run(p, &a, &cycles);
    CHECK(rc == ACCEL_OK, "%s: accel_run returned %d", s->name, rc);
    if (rc != ACCEL_OK) goto done;

    uint8_t *raw = malloc(4 * n_out + MARGIN);
    dma_copy(raw, dout.virt, 4 * n_out + MARGIN);
    size_t bad = 0, written = 0;
    for (int k = 0; k < s->k; k++)
        for (int oy = 0; oy < oh; oy++)
            for (int ox = 0; ox < ow; ox++) {
                int32_t acc = b[k];
                for (int c = 0; c < s->c; c++)
                    for (int fy = 0; fy < s->fy; fy++)
                        for (int fx = 0; fx < s->fx; fx++) {
                            int iy = oy * s->stride - s->pad + fy, ix = ox * s->stride - s->pad + fx;
                            if (iy < 0 || iy >= s->h || ix < 0 || ix >= s->w) continue;
                            acc += x[accel_elem(c, iy, ix, s->h, s->w, s->inl)] * w[((k * s->c + c) * s->fy + fy) * s->fx + fx];
                        }
                int32_t got;
                size_t e = accel_elem(k, oy, ox, oh, ow, s->outl);
                memcpy(&got, raw + 4 * e, 4);
                if (got != acc) {
                    if (bad++ < 3) printf("  result k=%d oy=%d ox=%d: got %d, expected %d\n", k, oy, ox, got, acc);
                }
                written++;
            }
    CHECK(bad == 0, "%s: %zu of %zu results are wrong", s->name, bad, written);
    size_t untouched = 0;
    for (size_t i = 0; i < 4 * n_out + MARGIN; i++) untouched += raw[i] == FILL;
    CHECK(untouched >= (n_out - written) * 4 + MARGIN, "%s: the padding lanes or the bytes after the output were written", s->name);
    printf("%s: %zu results, CYCLES %u\n", s->name, written, cycles);
    free(raw);
done:
    free(x);
    free(w);
    free(b);
}

int main(int argc, char **argv) {
    const char *backend;
    platform_t p = platform_open(&argc, argv, &backend);
    if (argc > 1) {
        fprintf(stderr, "usage: %s [--regs <addr> --mem <addr>:<size>]\n", argv[0]);
        return 2;
    }
    printf("accelerator: %s\n", backend);
    test_status(&p);
    test_registers(&p);
    for (unsigned i = 0; i < sizeof SHAPES / sizeof SHAPES[0]; i++) test_layer(&p, &SHAPES[i]);
    printf(fails ? "FAILED, %d checks\n" : "all checks pass\n", fails);
    platform_close();
    return fails != 0;
}
