/* ARM side driver of the conv accelerator
 * the driver only talks to a platform_t: registers, DMA buffers and cache maintenance are provided by a backend
 * (accel_sim.c is a software stand-in, a board backend comes with the block design)
 * layouts are the ones of the hardware (docs/plans/vhdl-accelerator-tasks.md D3):
 *   input  int8  [C/L][H][W][L], L = in_lanes, L = 1 is the plain [H][W] raw frame
 *   weight int8  [K][C][FY][FX], bias int32 [K], both plain
 *   output int32 [K/L][OH][OW][L], L = out_lanes, the accumulator with the bias included, no requant
 */
#ifndef ACCEL_H
#define ACCEL_H

#include <stddef.h>
#include <stdint.h>

#define ACCEL_LANES 16

#define ACCEL_OK 0
#define ACCEL_ERR_BUSY (-1)    /* the accelerator was busy at the start */
#define ACCEL_ERR_TIMEOUT (-2) /* done did not rise in time */
#define ACCEL_ERR_HW (-3)      /* STATUS.error is set */

typedef struct {
    void *virt;     /* address for the ARM */
    uint32_t phys;  /* address for the accelerator */
    size_t size;
} dma_buf_t;

typedef struct {
    void *ctx;
    void (*reg_write)(void *ctx, uint32_t off, uint32_t val);
    uint32_t (*reg_read)(void *ctx, uint32_t off);
    dma_buf_t (*alloc)(void *ctx, size_t size);          /* contiguous, aligned to 64 bytes */
    void (*flush)(void *ctx, const dma_buf_t *b);        /* the ARM wrote it, the accelerator will read it */
    void (*invalidate)(void *ctx, const dma_buf_t *b);   /* the accelerator wrote it, the ARM will read it */
} platform_t;

typedef struct {
    int c, k, h, w, fy, fx, stride, pad, in_lanes, out_lanes;
    const dma_buf_t *in, *wt, *bias, *out;
} accel_layer_t;

/* element index of channel c at (y, x) of an h x w map with l lanes, same formula as camus_pkg.elem_addr */
static inline size_t accel_elem(int c, int y, int x, int h, int w, int l) {
    return (((size_t)(c / l) * h + y) * w + x) * l + c % l;
}

static inline int accel_out_dim(int i, int f, int s, int p) { return (i + 2 * p - f) / s + 1; }

/* copy into or out of DMA memory with byte accesses, memcpy may use multi word accesses that an uncached mapping
 * (board_platform.h) does not take; fine for the one time uploads and the 12.5 KB frame, not for the large maps */
static inline void dma_copy(void *dst, const void *src, size_t n) {
    volatile uint8_t *d = dst;
    const volatile uint8_t *s = src;
    while (n--) *d++ = *s++;
}

/* run one conv layer: flush the inputs, write the registers, start, poll STATUS, invalidate the output
 * returns ACCEL_OK or an ACCEL_ERR_*, *cycles gets the CYCLES register on success (cycles may be NULL) */
int accel_run(const platform_t *p, const accel_layer_t *l, uint32_t *cycles);

#endif
