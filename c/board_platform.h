/* Board backend of the conv accelerator: platform_t over /dev/mem, for Linux on the Zynq (not tested on a board yet)
 * registers: the AXI-Lite slave at regs_phys, read and written with volatile 32 bit accesses
 * DMA memory: a range of DDR that Linux must not use (kernel mem= argument or reserved-memory in the device tree),
 *   mapped uncached (O_SYNC), so flush and invalidate only order the accesses, no cache maintenance is needed
 * the addresses come from the block design (Vivado address editor) and the boot setup, they are parameters, not constants
 * decision A of the board backend discussion: simplest for v1, the ARM steps are slow on uncached memory, see accel.h dma_copy
 */
#ifndef BOARD_PLATFORM_H
#define BOARD_PLATFORM_H

#include <stddef.h>
#include <stdint.h>

#include "accel.h"

typedef struct board board_t;

/* maps the registers (one page at regs_phys) and the DMA range, exits with a message on failure
 * mem_phys must be page aligned and mem_phys + mem_size must fit in 32 bits */
board_t *board_open(uint32_t regs_phys, uint32_t mem_phys, size_t mem_size);
void board_close(board_t *b);
platform_t board_platform(board_t *b);

#endif
