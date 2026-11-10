/* ARM side driver of the conv accelerator, see accel.h */
#include <time.h>

#include "accel.h"
#include "accel_regs.h"

#define TIMEOUT_MS 60000.0   /* v1 needs seconds per frame, this is per layer */

static double now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

int accel_run(const platform_t *p, const accel_layer_t *l, uint32_t *cycles) {
    if (p->reg_read(p->ctx, ACCEL_REG_STATUS) & ACCEL_STATUS_BUSY) return ACCEL_ERR_BUSY;

    p->flush(p->ctx, l->in);
    p->flush(p->ctx, l->wt);
    p->flush(p->ctx, l->bias);

    p->reg_write(p->ctx, ACCEL_REG_C, l->c);
    p->reg_write(p->ctx, ACCEL_REG_K, l->k);
    p->reg_write(p->ctx, ACCEL_REG_H, l->h);
    p->reg_write(p->ctx, ACCEL_REG_W, l->w);
    p->reg_write(p->ctx, ACCEL_REG_FY, l->fy);
    p->reg_write(p->ctx, ACCEL_REG_FX, l->fx);
    p->reg_write(p->ctx, ACCEL_REG_STRIDE, l->stride);
    p->reg_write(p->ctx, ACCEL_REG_PAD, l->pad);
    p->reg_write(p->ctx, ACCEL_REG_IN_LANES, l->in_lanes);
    p->reg_write(p->ctx, ACCEL_REG_OUT_LANES, l->out_lanes);
    p->reg_write(p->ctx, ACCEL_REG_IN_BASE, l->in->phys);
    p->reg_write(p->ctx, ACCEL_REG_W_BASE, l->wt->phys);
    p->reg_write(p->ctx, ACCEL_REG_B_BASE, l->bias->phys);
    p->reg_write(p->ctx, ACCEL_REG_OUT_BASE, l->out->phys);

    p->reg_write(p->ctx, ACCEL_REG_CTRL, ACCEL_CTRL_START);

    double t0 = now_ms();
    uint32_t st;
    while (!((st = p->reg_read(p->ctx, ACCEL_REG_STATUS)) & ACCEL_STATUS_DONE))
        if (now_ms() - t0 > TIMEOUT_MS) return ACCEL_ERR_TIMEOUT;

    if (st & ACCEL_STATUS_ERROR) return ACCEL_ERR_HW;
    p->invalidate(p->ctx, l->out);
    if (cycles) *cycles = p->reg_read(p->ctx, ACCEL_REG_CYCLES);
    return ACCEL_OK;
}
