/* Register map of the conv accelerator (vhdl/src/interface/axi_lite_regs.vhd, docs/plans/axi-interfaces.md section 6)
 * byte offsets from the base address of the AXI-Lite slave, all registers are 32 bit */
#ifndef ACCEL_REGS_H
#define ACCEL_REGS_H

#define ACCEL_REG_CTRL 0x00      /* write only, reads 0 */
#define ACCEL_REG_STATUS 0x04    /* read only */
#define ACCEL_REG_C 0x08
#define ACCEL_REG_K 0x0C
#define ACCEL_REG_H 0x10
#define ACCEL_REG_W 0x14
#define ACCEL_REG_FY 0x18
#define ACCEL_REG_FX 0x1C
#define ACCEL_REG_STRIDE 0x20
#define ACCEL_REG_PAD 0x24
#define ACCEL_REG_IN_LANES 0x28
#define ACCEL_REG_OUT_LANES 0x2C
#define ACCEL_REG_IN_BASE 0x30
#define ACCEL_REG_W_BASE 0x34
#define ACCEL_REG_B_BASE 0x38
#define ACCEL_REG_OUT_BASE 0x3C
#define ACCEL_REG_CYCLES 0x40    /* read only, clocks from start until done */

#define ACCEL_CTRL_START 0x1u
#define ACCEL_CTRL_SOFT_RST 0x2u /* wins over start */

#define ACCEL_STATUS_BUSY 0x1u
#define ACCEL_STATUS_DONE 0x2u   /* sticky until the next start or soft reset */
#define ACCEL_STATUS_ERROR 0x4u  /* sticky, a bus error, or a start while busy */

#endif
