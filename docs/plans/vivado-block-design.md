# Vivado block design for the v1 accelerator: checklist (task 3.3)

Status: a checklist to follow by hand, written 2026-11-10 and revised 2026-11-18 for the **ZedBoard** (Zynq-7000 XC7Z020), the board in the lab and the first target. The Ultra96 values are kept in the table and in section 9, because the Ultra96 stays the final target. It was written without Vivado access, **nothing here has been run in Vivado** except what is said in section 4a. Facts marked *(check)* are from memory; confirm them in the tool and in UG585 (Zynq-7000), and correct this file. The register map is in [axi-interfaces.md section 6](axi-interfaces.md#6-register-map-proposal-implemented-in-axi_lite_regs), the top level in [vhdl-modules.md](vhdl-modules.md#conv_accel_top-task-23), the board differences in [axi-ddr-master.md section 3](axi-ddr-master.md#3-platforms), how to reach the board in [connect-to-board.md](../connect-to-board.md).

| | **ZedBoard** (first target) | Ultra96 (later) |
|---|---|---|
| `BOARD` in `camus_pkg.vhd` | `ZEDBOARD` (the file has `ULTRA96` today, change it) | `ULTRA96` |
| Wrapper file (top of the block design) | `conv_accel_bd_zed.vhd` (64 bit) | `conv_accel_bd.vhd` (128 bit) |
| Vivado part | `xc7z020clg484-1` *(check)* | `xczu3eg-sbva484-1-e` *(check)* |
| PS IP | ZYNQ7 Processing System | Zynq UltraScale+ MPSoC |
| Control port (PS master) | `M_AXI_GP0` | `M_AXI_HPM0_LPD` or `M_AXI_HPM0_FPD` |
| Data port (PS slave) | `S_AXI_HP0`, 64 bit, AXI3 | `S_AXI_HP0_FPD`, 128 bit, AXI4 |
| PL clock / reset | `FCLK_CLK0` / `FCLK_RESET0_N` | `pl_clk0` / `pl_resetn0` |
| Protocol converter on `m_axi` | AXI4 to AXI3, in the interconnect | none |
| ARM | 2 x Cortex-A9, 32-bit (`armhf`) | 4 x Cortex-A53, 64-bit (`aarch64`) |

Picture (ZedBoard names):

```
 PS7 (Zynq-7000)                                         PL
 +----------------+  M_AXI_GP0     +-------------+  s_axi   +------------------+
 |  ARM A9        |--------------->| AXI         |--------->|                  |
 |                |  FCLK_CLK0     | SmartConnect|          | conv_accel_bd_zed|
 |  DDR           |                +-------------+          |  (conv_accel_top)|
 |   ^            |  S_AXI_HP0     +-------------+  m_axi   |  aclk, aresetn   |
 |   +------------|<---------------| AXI         |<---------|                  |
 +----------------+                | SmartConnect|          +------------------+
                                   +-------------+     Processor System Reset -> aresetn
```

## 0. Before Vivado

- [ ] **Set the board in the RTL:** in `vhdl/src/camus_pkg.vhd` change `constant BOARD : board_t := ULTRA96;` to `ZEDBOARD` (64-bit data port, AXI3 burst limit 16). The comment in that file says the default is only switched once it is agreed, so tell the team. If it does not match the wrapper, the wrapper fails to compile ("actual constraints don't match formal ones"), so it cannot go unnoticed.
- [ ] Re-run the simulation for that setting: `vhdl/tests/run_axi_regression.sh zedboard` (needs the GHDL LLVM/GCC backend), or run `tb_conv_accel_top` by hand as in its header. The top level has been simulated at 64 bit on the tiny layers and at 128 bit on tiny and golden layers.
- [ ] `ghdl --synth --std=08 conv_accel_bd_zed` runs through with `BOARD := ZEDBOARD`. This is no proof that Vivado accepts the code, only a first filter.

## 1. Add the RTL

All sources are VHDL-2008 (the testbenches and the aggregates in `axi_lite_regs` need it).

- [ ] Add the files of `vhdl/src/` in this set, nothing from `vhdl/tests/`: `camus_pkg`, `axi_pkg`, `compute-engine/{layer_setup,loop_nest,addr_gen,mac_int8,conv_core_v1,conv_engine_v1}`, `interface/{axi_lite_regs,sync_fifo,axi_skid,axi_master_rd,axi_master_wr,axi_ddr_master}`, `conv_accel_top`, and **one** wrapper: `conv_accel_bd_zed` for the ZedBoard (`conv_accel_bd` is the Ultra96 one, do not add both). `requant.vhd` is not instantiated by v1, leaving it out is fine.
- [ ] Set the file type of the sources to **VHDL 2008** (Tcl: `set_property file_type {VHDL 2008} [get_files *.vhd]`), **except the wrapper** (`conv_accel_bd_zed.vhd`, or `conv_accel_bd.vhd`), which must stay **plain VHDL**. Setting the wrapper to VHDL 2008 made the module reference invalid in Vivado (seen 2026-11-18, fixed by setting the wrapper back to plain VHDL; the other files stay 2008). The only 2008 construct GHDL reported is `process(all)` in `axi_master_rd.vhd`; the files that do not depend on it analyse as VHDL-93 (the ones that depend on it, including the wrapper, could not be checked that way). All go into library `work`.
- [ ] Elaborate and check there are no errors.

## 2. Make the top usable in the block design

Two ways, pick one. **Module reference** is quicker, **Package IP** is cleaner once it works.

**a) Module reference:** right click the block design, *Add Module*, choose **`conv_accel_bd_zed`** (not `conv_accel_top`). Vivado infers the two bus interfaces from the port names (`s_axi_*` is AXI4-Lite slave, `m_axi_*` is AXI4 master) *(check)*.

The wrapper exists because Vivado reads the ports of a module reference without the packages: `conv_accel_top` was reported incompatible on 2026-11-11 with `[IP_Flow 19-627] Port 'm_axi_rdata': XPath expression failed: Undefined parameter "AXI_DATA_W" used in expression "(AXI_DATA_W - 1)"` (the same for `m_axi_wdata` and `m_axi_wstrb`), `[IP_Flow 19-4668] Failed to infer definition from module`, `[BD 41-1699]`, and `[IP_Flow 19-1816] Address Space 'm_axi': Invalid addressSpace width value ""` (from `AXI_ADDR_W`). The wrappers have literal port widths, no generics and no package constants in their ports. Keep `conv_accel_top` in the project, the wrapper instantiates it. Not yet tried in Vivado.

**b) Package IP:** *Tools > Create and Package New IP* from the project (the wrapper as top). Same inference, then in the packager: *Ports and Interfaces* shows the two interfaces, *File Groups* must list all VHDL files as VHDL 2008.

- [ ] Both interfaces are found: `s_axi` (AXI4-Lite, **slave**, 32 bit data, 8 address bits) and `m_axi` (AXI4, **master**, 32 bit address, 64 bit data on the ZedBoard).
- [ ] `aclk` is the clock of **both** interfaces, `aresetn` is an **active-low** reset. If Vivado does not associate them by itself (typical warning: a bus interface without an associated clock, or an unknown `FREQ_HZ`), fix it in the packager (*Ports and Interfaces > clock > Associated Bus Interfaces = `s_axi:m_axi`*, reset polarity *ACTIVE_LOW*). For a module reference the same information can be put into the RTL as attributes on the wrapper ports, which are **not in the file yet and untested**:
  ```vhdl
  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;
  attribute X_INTERFACE_INFO of aclk : signal is "xilinx.com:signal:clock:1.0 aclk CLK";
  attribute X_INTERFACE_PARAMETER of aclk : signal is "ASSOCIATED_BUSIF s_axi:m_axi, ASSOCIATED_RESET aresetn";
  attribute X_INTERFACE_INFO of aresetn : signal is "xilinx.com:signal:reset:1.0 aresetn RST";
  attribute X_INTERFACE_PARAMETER of aresetn : signal is "POLARITY ACTIVE_LOW";
  ```
- [ ] `m_axi` ID width is 2 bits. The HP port has 6 ID bits *(check)*; a narrower master ID is normally fine, but look for a width warning.
- [ ] There is no `awprot`/`arprot` on `s_axi`, and no interrupt. Vivado leaves the optional signals unconnected, that is expected.

## 3. Block design (ZedBoard)

- [ ] **ZYNQ7 Processing System** IP. Click *Run Block Automation*; if the ZedBoard board files are installed (Digilent, *(check)*) this applies the board preset, otherwise the DDR3 and MIO settings of the ZedBoard have to be entered by hand.
- [ ] PS configuration (double-click the block):
  - [ ] *PS-PL Configuration > GP Master AXI Interface:* enable **M AXI GP0 interface**.
  - [ ] *HP Slave AXI Interface:* enable **S AXI HP0 interface**, data width **64** (must equal `AXI_DATA_W`).
  - [ ] *Clock Configuration > PL Fabric Clocks:* enable **FCLK_CLK0**, requested frequency **10 MHz** for the first v1 (the ZedBoard build had a worst path of about 79 ns at a 25 ns target, see section 5); with the rewritten `addr_gen` the board ran the whole network at about 66.7 MHz (a request of 70 MHz; 75 MHz failed in `b2c2`), see [addr-gen-rewrite.md](addr-gen-rewrite.md#result). If the PS block keeps generating a 10 MHz constraint, see section 5. Read the Actual Frequency column.
- [ ] Add **Processor System Reset** and two **AXI SmartConnect** blocks (1 slave interface, 1 master interface, 1 clock each).
- [ ] Buses: `M_AXI_GP0` to SmartConnect 0, SmartConnect 0 to `s_axi`. `m_axi` to SmartConnect 1, SmartConnect 1 to `S_AXI_HP0`. The SmartConnects convert AXI3 to AXI4-Lite and AXI4 to AXI3 *(check)*; bursts are at most 16 beats, so the master never exceeds the AXI3 limit.
- [ ] **One clock net** `FCLK_CLK0` to: `M_AXI_GP0_ACLK`, `S_AXI_HP0_ACLK`, `aclk`, both SmartConnects, `slowest_sync_clk` of the reset block. The accelerator has no clock-domain crossing, so all must be the same clock.
- [ ] Reset: `FCLK_RESET0_N` to `ext_reset_in`; `peripheral_aresetn` to `aresetn` and to both SmartConnects.
- [ ] **Address Editor** (*Window > Address Editor*, then *Auto Assign Address*):
  - [ ] `s_axi` gets a range (the GP0 window is `0x4000_0000` to `0x7FFF_FFFF`; the first slave often lands on `0x43C0_0000` *(check)*). **Write the base address down: it is the `--regs` value of `accel_probe`.** The registers occupy 0x00 to 0x44, the rest of the range reads 0.
  - [ ] `m_axi` sees the DDR through HP0 (segment `HP0_DDR_LOWOCM`, 512 MB at `0x0000_0000` *(check)*). If the DDR segment is not assigned the accelerator's reads hang or return errors.
- [ ] *Validate Design* (F6) has no errors. Read each warning, in particular about clock association, `FREQ_HZ` and ID width.
- [ ] *Create HDL Wrapper* (let Vivado manage it), set it as top.

## 4. Build

- [ ] Run synthesis. Look at the messages for inferred latches, ignored attributes, and RAM inference of the FIFOs in the masters (check how Vivado maps them, it should not use many BRAMs).
- [ ] Run implementation, then bitstream. For loading from Linux also tick *Settings > Bitstream > `-bin_file`* so a `.bin` is written next to the `.bit` *(check)*.
- [ ] Fill in the **results sheet** (section 7).

## 4a. Early timing without the block design (optional)

The block design needs **no XDC**: the accelerator has no pins, and the PS IP brings the pin constraints and the clock constraint of the PL clock. To see timing and utilization of the design alone, before the block design exists, use [vhdl/constraints/conv_accel_top_ooc.xdc](../../vhdl/constraints/conv_accel_top_ooc.xdc) (not run in Vivado yet):

- [ ] New RTL project with the part of the board in use (table at the top), the sources of section 1, the XDC as a constraint file with *Used in: Synthesis* only, top = `conv_accel_top`.
- [ ] *Settings > Synthesis > More Options:* `-mode out_of_context`. Otherwise Vivado puts I/O buffers on the AXI ports, which are no real pins.
- [ ] Run synthesis, then *Report Timing Summary* and *Report Utilization* on the synthesized design. Do **not** implement this run (the ports have no pin locations).
- [ ] **Known error when the run is not out of context:** `[Place 30-415] IO Placement failed due to overutilization. This design contains 502 I/O ports while the target device ... xczu3eg package: sbva484, contains only 297 available user I/O`, followed by `[Place 30-68] aclk_IBUF_BUFG_inst is not placed` and `[Place 30-99]`. Seen on 2026-11-11 with the Ultra96 part and `BOARD := ULTRA96`. This is **not a design error**. Vivado treated the AXI ports as real pins and put I/O buffers on them (the `IBUF` in the message shows it). The port count is about 500 at 128 bit and about 370 at 64 bit, so it fails on both parts. Fix: `-mode out_of_context` for synthesis and stop after synthesis, or use the block design.
- [ ] If post-route numbers are wanted before the block design exists, an out-of-context module can be implemented too, but it needs a clock location for the port (UG905: `set_property HD.CLK_SRC BUFGCTRL_X0Y0 [get_ports aclk]` *(check the syntax and the site name for the part)*). That line is **not** in the XDC because I cannot test it. The simpler route is the block design.
- [ ] The clock is 100 MHz (`-period 10.000`). Edit the XDC for another period.
- [ ] The result is only an estimate: after synthesis there is no routing delay yet, and the 2 ns port budget in the XDC is an assumption.

## 5. Timing and resources

- [ ] *Report Timing Summary:* WNS and TNS at the chosen clock. **Seen on the Ultra96 build at 100 MHz (2026-11-18): WNS about -15 ns**, for example from `u_regs/s_regs_reg...` to `u_engine/u_core/s_out_addr_d1_reg`. The cause is the combinational address arithmetic in `addr_gen` (divisions by run-time values and chained 32-bit multiplications, all in one clock). So v1 needs a low clock until that logic is pipelined or rewritten. **Seen on the ZedBoard build (2026-11-18): target 25 ns (40 MHz), actual worst path about 79 ns.** Decision 2026-11-18: the RTL stays as it is for now and the bring-up runs at **10 MHz** (100 ns period, which leaves room for the 79 ns path; do not go much higher). The proper fix, precomputing the layer constants at start and making each address from running counters (no division, no chained multiplications), is deferred. **Measured on the board at 10 MHz (2026-11-18, `accel_probe`, CYCLES register):** tiny_a 251608 clocks for 5670 MACs (44 per MAC), tiny_b 1196967 for 29160 (41), tiny_c 30242 for 612 (49), tiny_d 12574 for 288 (44), tiny_e 7152 for 100 (72, one MAC per output). So v1 needs about **41 to 44 clocks per MAC** on the real DDR port, about twice the ~22 seen in simulation, where the memory model answers in 0 to 3 clocks. Consequences at 10 MHz (arithmetic from those numbers): about 37.4 M MACs per frame x 41 to 44 = 1.5 to 1.65 G clocks, so **about 150 to 165 s per frame**, and the largest layers (7.2 M MACs) about 30 s each, inside the driver's 60 s per-layer timeout with a factor of two to spare. So run `camus_accel` with 1 or 2 frames, not 200, and the nine `accel_golden` layers one by one.
- [ ] *Report Utilization:* DSP count (v1 has one MAC, expect very few DSPs), BRAM, LUT.
- [ ] **2026-11-25: the PS block generated a 100 ns (10 MHz) clock constraint although `FCLK_CLK0` was set to 75 and 100 MHz.** The cause was not found, although the PS setting, `Validate Design`, resetting and regenerating the output products and resetting all runs were done. So the bitstreams of that day were never timing-checked at their real clock, and the "longest path of about 9 ns" is not a result for 100 MHz. On the board the same bitstream worked at 10, 50 and about 66.7 MHz, and failed at 75 MHz in `b2c2` and once in the probe at a higher clock. A workaround file exists, [vhdl/constraints/zed_fclk0_override.xdc](../../vhdl/constraints/zed_fclk0_override.xdc) (not run in Vivado yet). What is needed: a build whose Timing Summary (the file under *Reports*, not an open window) shows the target period with WNS >= 0.
- [ ] Frame time follows from the clock: the v1 estimate of about 22 clocks per MAC from simulation gives about 0.8 G clocks per frame, about 80 s at 10 MHz and about 20 s at 40 MHz (arithmetic from simulation numbers, **superseded by the board measurement above: 41 to 44 clocks per MAC, so about 150 to 165 s per frame at 10 MHz**). The real clock on the board is what the boot image or the `fclk` setting gives, see section 6.

## 6. To the board (ZedBoard)

The way to the board is [connect-to-board.md](../connect-to-board.md) (UART, Ethernet, U-Boot, `wget` from the PC).

- [ ] **Build the package on the PC** (Docker running): `make package-accel` in `c/` writes `build/board-accel.tar.gz` with the armhf binaries `accel_probe`, `accel_golden`, `camus_accel`, the sources, `build/export` and golden frame `f000` (built 2026-11-18, programs tested against the stand-in under `qemu-arm`, not on the board). In the ZedBoard block design of 2026-11-18 `s_axi` was at `0x4000_0000`, so `--regs 0x40000000`. Put the bitstream next to it in `build/` (see below), so one `python3 -m http.server` serves both.
- [ ] **Reserve DDR for the DMA buffers** by shortening the memory the kernel sees. In U-Boot add `mem=496M` to the boot arguments of Step 3 of `connect-to-board.md`: `setenv bootargs console=ttyPS0,115200 rdinit=/bin/sh init=/bin/sh mem=496M`, then `boot`. That leaves `0x1F00_0000` to `0x1FFF_FFFF` (16 MB) free *(check the DDR size, 512 MB assumed)*, and the range for the programs is `--mem 0x1F000000:0x1000000`. About 1 MB is enough.
- [ ] **Where the PL clock comes from:** the PS settings of your block design are **not** applied by the bitstream. On the Zynq-7000 the clocks and the PS interfaces are set up by the boot image on the SD card (the first stage boot loader built for some other design), so `FCLK_CLK0` runs at whatever that image sets, maybe 100 MHz, maybe off *(check)*. The accelerator must not run faster than the clock it was built for. Find out before loading, from the board shell: `cat /sys/devices/soc0/amba/f8007000.devcfg/...` or by reading the clock register `FPGA0_CLK_CTRL` at `0xF8000170` through `/dev/mem`. On the Xilinx kernel the clock can be set with `echo fclk0 > /sys/devices/soc0/amba/f8007000.devcfg/fclk_export`, then `echo 10000000 > /sys/class/fclk/fclk0/set_rate` (10 MHz, the clock the bitstream was built for; never run the PL faster than that) *(all paths from memory, check what exists on this image)*.
- [ ] Paths seen on the lab image on 2026-11-18 (Linux 4.0.0-xilinx-dev): `/dev/xdevcfg` exists, the devcfg device is `/sys/devices/soc0/amba/f8007000.devcfg` with `fclk_export`, `fclk_unexport`, `prog_done` and `is_partial_bitstream`; `/sys/class/fclk` exists and is empty until `fclk0` is exported.
- [ ] **Load the bitstream:** on the Xilinx Linux 4.0 kernel the PL is loaded with `cat design_1_wrapper.bit.bin > /dev/xdevcfg` *(check)*. If the board rejects Vivado's `.bin`, convert the `.bit` with bootgen: a file `full.bif` containing `all:{ design_1_wrapper.bit }` and `bootgen -image full.bif -arch zynq -process_bitstream bin` *(check)*. Check that it worked: `cat /sys/devices/soc0/amba/f8007000.devcfg/prog_done` should print `1` *(check)*.
- [ ] Typical first sign of a wrong address map or a missing PL clock: reading a register hangs the CPU. The shell cannot be interrupted (`Ctrl+C` does not work in this setup), only *Reset* helps.
- [ ] Run, in this order (commands in [software.md](../software.md#arm-side-of-the-accelerator-c)): `accel_probe`, `accel_golden` for the small layers first (`b3sc`, `b2sc`, `stem`) and then all nine, then `camus_accel`. The package already contains `build/export/golden/f000`.

## 7. Results sheet (fill in)

| Item | Value |
|---|---|
| Board, Vivado version | |
| `BOARD` in `camus_pkg` | `ZEDBOARD` |
| PS board preset / DDR settings | |
| PL clock requested / actual in the running board | requested 10 MHz; the lab boot image started `FCLK_CLK0` at 99999999 Hz, set to 10 MHz through `/sys/class/fclk/fclk0/set_rate` after loading the bitstream |
| WNS / TNS | |
| DSP / BRAM / LUT | |
| `s_axi` base address | `0x4000_0000` |
| DDR segment seen by `m_axi` | |
| HP port data width, converter inserted | |
| Reserved DMA range | `0x1F00_0000`, 16 MB (`mem=496M`, plus `initrd_high` and `fdt_high` set to `0xffffffff` in U-Boot) |
| Bitstream load method | `cat <file>.bin > /dev/xdevcfg`, `prog_done` read from `/sys/devices/soc0/amba/f8007000.devcfg` |
| `accel_probe` | all checks pass; CYCLES tiny_a 251608, tiny_b 1196967, tiny_c 30242, tiny_d 12574, tiny_e 7152 |
| `accel_golden` layers passed | all nine bit-exact (reported by the team, CYCLES values not recorded yet) |
| `camus_accel` bit-exact / frame time | yes (0 of 2 frames differ); 176.5 s per frame wall time, 1,764,192,598 accelerator clocks per frame (2026-11-18, 10 MHz) |
| `camus_accel` with the new address generation (2026-11-25) | yes (0 of 5 frames differ); 33.80 s per frame, 2,245,339,410 clocks per frame, PL clock about 66.7 MHz after a request of 70 MHz (75 MHz failed in `b2c2`); WNS not recorded, the Vivado build used a 10 MHz constraint |

## 8. Facts to look up (ZedBoard)

See also [axi-ddr-master.md section 3.4](axi-ddr-master.md#34-check-on-the-zedboard-facts-not-yet-confirmed).

- [ ] The HP port protocol (AXI3), width (64) and ID bits (6), and whether the SmartConnect inserts the AXI4 to AXI3 converter by itself.
- [ ] The maximum HP port clock, and whether the design closes timing at 40 MHz and higher on the XC7Z020.
- [ ] The DDR size and its address range as seen from the HP ports.
- [ ] What the boot image of the SD card sets: PL clock frequency, GP0 and HP0 enabled, level shifters.
- [ ] How the PL is loaded on this kernel (`/dev/xdevcfg`, format of the `.bin`), and which `fclk` files exist.

## 9. Ultra96 (later)

The same plan with the other names, as in the table at the top. Seen in the Address Editor on 2026-11-18 (Ultra96 block design): `s_axi` at `0x8000_0000` (the `--regs` value is `0x80000000`), `HP0_DDR_LOW` at `0x0000_0000`, `HP0_LPS_OCM` at `0xFF00_0000` (on-chip memory, unused). In short:

- [ ] Wrapper `conv_accel_bd.vhd` (128 bit), `BOARD := ULTRA96`, **Zynq UltraScale+ MPSoC** IP with the board preset if the board files are installed, `M_AXI_HPM0_LPD` (or FPD) and `S_AXI_HP0_FPD` at 128 bit, `pl_clk0`, `pl_resetn0`, the same two SmartConnects and reset block, no AXI3 converter. The master has a 32-bit address and the port 49 bits, check that validation does not complain.
- [ ] DMA range for the 2 GB DDR: the top 16 MB, `--mem 0x7F000000:0x1000000`, reserved with a `reserved-memory` node or `mem=2032M` *(check)*.
- [ ] The A53 cores run 64-bit code, so the `armhf` binaries will most likely not run there: `make package64` in `c/` writes `build/board64.tar.gz` (static aarch64 binaries, sources, `build/export` and golden frame `f000`). The `radl-tf1` image has no aarch64 compiler, so run `apt-get update && apt-get install -y gcc-aarch64-linux-gnu` in the container first (checked 2026-11-11: warning free, bit-exact against the stand-in under `qemu-aarch64`).
- [ ] Facts to look up: the HP port protocol (AXI4 expected) and ID bits, the address window of the PS master port and the DDR segment seen by `S_AXI_HP0_FPD`, the maximum clock of the HP port, and how the OS image (PYNQ or PetaLinux) loads a bitstream and reserves memory.
