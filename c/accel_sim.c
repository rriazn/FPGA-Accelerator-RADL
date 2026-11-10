/* Software stand-in of the conv accelerator, see accel_sim.h */
#include <stdlib.h>
#include <string.h>

#include "accel_regs.h"
#include "accel_sim.h"

#define ARENA_PHYS 0x10000000u   /* fake physical address of the arena */
#define LATENCY_POLLS 3          /* STATUS reads that show busy after a start */
#define N_REGS 17

struct sim {
    uint8_t *mem;
    size_t size, used;
    uint32_t regs[N_REGS];       /* word index = byte offset / 4, CTRL and STATUS are not stored */
    int busy, done, error, polls_left;
    uint32_t cycles;
    unsigned long layers;
    unsigned long long macs;
};

/* bits that exist in each layer register, as in axi_lite_regs */
static uint32_t reg_mask(int idx) {
    switch (idx) {
    case 2: case 3: case 4: case 5: return 0xFFFF;
    case 6: case 7: case 8: case 9: return 0x7;
    case 10: case 11: return 0x1F;
    default: return 0xFFFFFFFFu;
    }
}

static int clamp(uint32_t v, int lo, int hi) {
    int n = (int)(v & 0xFFFF);
    return n < lo ? lo : n > hi ? hi : n;
}

/* ARM pointer of a physical range inside the arena, NULL if any byte is outside */
static uint8_t *map(const sim_t *s, uint32_t phys, size_t len) {
    if (phys < ARENA_PHYS || (uint64_t)phys - ARENA_PHYS + len > s->size) return NULL;
    return s->mem + (phys - ARENA_PHYS);
}

/* the conv of conv_engine_v1: acc = bias + sum x * w, zero padding, int32 output, padding lanes are not written */
static void run_layer(sim_t *s) {
    const uint32_t *r = s->regs;
    int c = r[2] & 0xFFFF, k = r[3] & 0xFFFF, h = r[4] & 0xFFFF, w = r[5] & 0xFFFF;
    int fy = clamp(r[6], 1, 7), fx = clamp(r[7], 1, 7), stride = clamp(r[8], 1, 7), pad = clamp(r[9], 0, 7);
    int inl = clamp(r[10], 1, ACCEL_LANES), outl = clamp(r[11], 1, ACCEL_LANES);
    if (!c || !k || !h || !w || h + 2 * pad < fy || w + 2 * pad < fx) {
        s->error = 1;
        return;
    }
    int oh = accel_out_dim(h, fy, stride, pad), ow = accel_out_dim(w, fx, stride, pad);
    size_t n_in = (size_t)((c + inl - 1) / inl) * h * w * inl;
    size_t n_out = (size_t)((k + outl - 1) / outl) * oh * ow * outl;
    const int8_t *x = (const int8_t *)map(s, r[12], n_in);
    const int8_t *wt = (const int8_t *)map(s, r[13], (size_t)k * c * fy * fx);
    const uint8_t *bias = map(s, r[14], 4 * (size_t)k);
    uint8_t *out = map(s, r[15], 4 * n_out);
    if (!x || !wt || !bias || !out) {
        s->error = 1;
        return;
    }
    for (int ko = 0; ko < k; ko++) {
        int32_t b;
        memcpy(&b, bias + 4 * ko, 4);
        for (int oy = 0; oy < oh; oy++)
            for (int ox = 0; ox < ow; ox++) {
                int32_t acc = b;
                for (int ci = 0; ci < c; ci++)
                    for (int dy = 0; dy < fy; dy++)
                        for (int dx = 0; dx < fx; dx++) {
                            int iy = oy * stride - pad + dy, ix = ox * stride - pad + dx;
                            if (iy < 0 || iy >= h || ix < 0 || ix >= w) continue;
                            acc += x[accel_elem(ci, iy, ix, h, w, inl)] * wt[((ko * c + ci) * fy + dy) * fx + dx];
                        }
                memcpy(out + 4 * accel_elem(ko, oy, ox, oh, ow, outl), &acc, 4);
            }
    }
    s->cycles = (uint32_t)((unsigned long long)k * oh * ow * c * fy * fx);
    s->layers++;
    s->macs += (unsigned long long)k * oh * ow * c * fy * fx;
}

static void reg_write(void *ctx, uint32_t off, uint32_t val) {
    sim_t *s = ctx;
    int idx = off >> 2;
    if (idx == 0) {
        if (val & ACCEL_CTRL_SOFT_RST) {
            s->busy = s->done = s->error = 0;
        } else if (val & ACCEL_CTRL_START) {
            if (s->busy) {
                s->error = 1;
            } else {
                s->busy = 1;
                s->done = s->error = 0;
                s->polls_left = LATENCY_POLLS;
            }
        }
    } else if (idx >= 2 && idx <= 15 && !s->busy) {
        s->regs[idx] = val & reg_mask(idx);
    }
}

static uint32_t reg_read(void *ctx, uint32_t off) {
    sim_t *s = ctx;
    int idx = off >> 2;
    if (idx == 1) {
        uint32_t v = (s->busy ? ACCEL_STATUS_BUSY : 0) | (s->done ? ACCEL_STATUS_DONE : 0) | (s->error ? ACCEL_STATUS_ERROR : 0);
        if (s->busy && --s->polls_left <= 0) {
            run_layer(s);
            s->busy = 0;
            s->done = 1;
        }
        return v;
    }
    if (idx == 16) return s->cycles;
    if (idx >= 2 && idx <= 15) return s->regs[idx];
    return 0;
}

static dma_buf_t alloc_buf(void *ctx, size_t size) {
    sim_t *s = ctx;
    size_t start = (s->used + 63) & ~(size_t)63;
    if (start + size > s->size) abort();
    s->used = start + size;
    dma_buf_t b = {s->mem + start, ARENA_PHYS + (uint32_t)start, size};
    return b;
}

/* the stand-in is coherent, nothing to do */
static void no_sync(void *ctx, const dma_buf_t *b) {
    (void)ctx;
    (void)b;
}

sim_t *sim_create(size_t arena_bytes) {
    sim_t *s = calloc(1, sizeof *s);
    s->mem = calloc(1, arena_bytes);
    s->size = arena_bytes;
    return s;
}

void sim_destroy(sim_t *s) {
    free(s->mem);
    free(s);
}

platform_t sim_platform(sim_t *s) {
    platform_t p = {s, reg_write, reg_read, alloc_buf, no_sync, no_sync};
    return p;
}

void sim_stats(const sim_t *s, unsigned long *layers, unsigned long long *macs) {
    *layers = s->layers;
    *macs = s->macs;
}
