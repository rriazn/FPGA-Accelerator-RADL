# AXI interfaces of the accelerator

Status: working summary of what `architecture-spec.md` (section 2) and `vhdl-modules.md` already say, written as one overview. The final target is the Avnet Ultra96 (Zynq UltraScale+ MPSoC, ARM Cortex-A53). The ZedBoard (Zynq-7000) was only used for the first test session, so its port names do not apply. The PS port names below are from memory and depend on the block design (D4, still open), so check them in Vivado.

## 1. Short answer

The accelerator has **two separate AXI connections**, and they are different kinds of AXI:

1. **Control link to the ARM** (PS to PL): AXI4-Lite, the accelerator is the **slave**.
2. **Data link to the DRAM** (PL to DDR): full AXI4 with bursts, the accelerator is the **master**.

The ARM never sends feature maps or weights to the accelerator. It only writes the DDR addresses into registers. The accelerator then fetches and stores the data itself.

## 2. Overview diagram

```
          control (AXI4-Lite)                        data (AXI4, bursts)
 +-----+   slave: accelerator          +-------------+          +------+
 | ARM | ----------------------------> | accelerator | -------> | DDR  |
 | PS  |   writes layer registers,     |     (PL)    | <------- | DRAM |
 |     |   start; polls status         | master:     |  reads inputs, weights, bias
 +-----+                               | accelerator |  writes results
    |                                  +-------------+          ^
    |                                                           |
    +-----------------------------------------------------------+
         ARM also reads and writes the same DDR buffers
         (copy frame in, requant / ReLU / pool / FC on results)
```

## 3. Comparison

| | Control link (ARM) | Data link (DRAM) |
|---|---|---|
| AXI type | AXI4-Lite | AXI4 (full, burst capable) |
| Accelerator role | slave | master |
| Who starts a transfer | the ARM | the accelerator |
| What it carries | layer registers: `IN_BASE`, `W_BASE`, `B_BASE`, `OUT_BASE`, layer dimensions, start, status, cycle count | inputs, weights and bias (read), int32 results (write) |
| Traffic | a few register writes per layer | nearly all of the bytes moved |
| Speed need | low, simple 32-bit registers | high, sets how fast the accelerator can run |
| MPSoC PS port (to confirm) | PS master port: `M_AXI_HPM0_LPD` (low power domain, enough for registers) or `M_AXI_HPM0_FPD` / `M_AXI_HPM1_FPD` | PS slave port: `S_AXI_HP0_FPD` to `S_AXI_HP3_FPD` (not coherent) or `S_AXI_HPC0_FPD` / `S_AXI_HPC1_FPD` (I/O coherent) |
| VHDL module | `axi_lite_regs` (task 1.4) | `axi_master_rd` and `axi_master_wr` (task 2.3) |
| Port names | `s_axi_*` | `m_axi_*` |

## 4. How one layer runs

1. The ARM puts the input feature map and the weights in DDR.
2. The ARM writes the layer registers over AXI-Lite (sizes, stride, padding, the four base addresses).
3. The ARM sets start.
4. The accelerator reads inputs, weights and bias from DDR through its AXI master, computes, and writes the int32 results back to DDR.
5. The ARM polls the status register (interrupt versus polling is open) and, when done, continues with requant, ReLU and the rest on the results.

## 5. Things that follow from this

- **Cache coherency.** The HP ports are not cache-coherent. The ARM caches and DDR can disagree, so the driver must flush the caches before the accelerator reads and invalidate them before the ARM reads the results, or use non-cached buffers. The Ultra96 also offers the HPC ports, which go through the cache coherent interconnect and make the accelerator I/O coherent, so the manual cache maintenance could be dropped. Choosing between HP and HPC is part of D4.
- **Data width.** One 128-bit AXI beat is 16 bytes, which is one pixel of a 16-channel block (L = 16) in int8. This is why the feature map layout is 16-channel-blocked (D3). `AXI_DATA_W = 128` is a generic, not a literal, because the width depends on the block design.
- **Byte addresses.** The registers hold byte addresses, and the AXI master takes byte addresses. Element addresses from the layout formula are converted in `addr_gen`.
- **v1 versus later.** v1 uses single-beat reads. Bursts (`len > 1`) come with the line buffers in step 4.1. From step 4.6 a second AXI read stream carries the skip tensor for the fused residual add.
- **Port naming.** The AXI ports keep their standard names (`s_axi_*`, `m_axi_*`) so Vivado can infer the interface bundles. Everything else follows the `i_`/`o_` convention.
- **Reset.** The top level inverts the active-low AXI reset once for the internal modules, which use the active-high `i_rst`.

## 6. Register map (proposal, implemented in `axi_lite_regs`)

All registers are 32 bit, word aligned, byte offsets from the base address of the IP. The ARM writes the layer registers with plain 32 bit stores, byte strobes are honored.

| Offset | Name | Access | Bits | Content |
|---|---|---|---|---|
| 0x00 | CTRL | write | 0 start, 1 soft reset | start is ignored (and sets error) while busy, soft reset wins over start, reads 0 |
| 0x04 | STATUS | read | 0 busy, 1 done, 2 error | done and error are sticky until the next start or soft reset |
| 0x08 | C | read, write | 15:0 | input channels |
| 0x0C | K | read, write | 15:0 | output channels |
| 0x10 | H | read, write | 15:0 | input height |
| 0x14 | W | read, write | 15:0 | input width |
| 0x18 | FY | read, write | 2:0 | kernel height |
| 0x1C | FX | read, write | 2:0 | kernel width |
| 0x20 | STRIDE | read, write | 2:0 | stride |
| 0x24 | PAD | read, write | 2:0 | symmetric padding |
| 0x28 | IN_LANES | read, write | 4:0 | L of the input layout (1 or 16) |
| 0x2C | OUT_LANES | read, write | 4:0 | L of the output layout (1 or 16) |
| 0x30 | IN_BASE | read, write | 31:0 | DDR byte address of the input |
| 0x34 | W_BASE | read, write | 31:0 | DDR byte address of the weights |
| 0x38 | B_BASE | read, write | 31:0 | DDR byte address of the bias |
| 0x3C | OUT_BASE | read, write | 31:0 | DDR byte address of the output |
| 0x40 | CYCLES | read | 31:0 | cycle counter from the accelerator |
| 0x44 to 0x7F | reserved | | | reads 0, writes ignored |
| 0x80 and up | step 4.6 | | | M0, SHIFT, flags, SKIP_BASE, SKIP_M0, SKIP_SHIFT |

Behavior worth knowing in the driver:

- **Lock while busy.** Layer register writes are ignored while STATUS.busy is 1 (the write is still answered with OKAY). CTRL stays writable, so the ARM can soft reset a running layer.
- **Unused bits.** Bits outside the listed field do not exist and read 0. FY, FX and STRIDE at 0 and LANES at 0 reach the datapath as 1, lanes above 16 as 16, so an unprogrammed register can never give an illegal configuration. The register still reads back what was written.
- **Polling.** Poll STATUS.done, not "not busy": busy may rise a clock or two after the start write. Done is cleared by the start, so it is safe to poll right after.
- **Unmapped offsets.** Reads return 0, writes are ignored, both answer OKAY (no SLVERR).
- **Interrupt.** None in this version, polling only.

## 7. Where to look

- `vhdl/src/interface/axi_lite_regs.vhd`: the AXI-Lite slave of section 6
- `architecture-spec.md`: section 2 (system), section 4 (layer registers), section 7 (DDR buffers)
- `vhdl-modules.md`: `axi_lite_regs`, `axi_master_rd`, `axi_master_wr` and the top level
- `vhdl-accelerator-tasks.md`: D4 (block design and bus width), tasks 1.4, 2.3 and 3.3
