/* Software stand-in of the conv accelerator behind a platform_t, for developing the ARM code without the board
 * it models the register file of axi_lite_regs and the result of conv_engine_v1 (same layouts and int32 output)
 * the conv runs when the polls of STATUS have counted down, so a driver that reads the output early gets garbage
 * CYCLES is the MAC count of the layer, not the clocks of the hardware */
#ifndef ACCEL_SIM_H
#define ACCEL_SIM_H

#include "accel.h"

typedef struct sim sim_t;

sim_t *sim_create(size_t arena_bytes);
void sim_destroy(sim_t *s);
platform_t sim_platform(sim_t *s);
/* layers run and MACs done since the creation */
void sim_stats(const sim_t *s, unsigned long *layers, unsigned long long *macs);

#endif
