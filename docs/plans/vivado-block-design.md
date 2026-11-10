# Vivado block design for the v1 accelerator: checklist (task 3.3)

Status: a checklist to follow by hand, written 2026-11-10 without Vivado access. **Nothing here has been run in Vivado.** Facts marked *(check)* are from memory; confirm them in the tool and in UG585 (Zynq-7000), and correct this file. Target now: ZedBoard (XC7Z020), later Ultra96, see [axi-ddr-master.md section 3](axi-ddr-master.md#3-platforms). The register map is in [axi-interfaces.md section 6](axi-interfaces.md#6-register-map-proposal-implemented-in-axi_lite_regs), the top level in [vhdl-modules.md](vhdl-modules.md#conv_accel_top-task-23).

Picture:

```
 Zynq PS7                                              PL
 +----------------+  M_AXI_GP0  +-------------+  s_axi   +------------------+
 |  ARM A9        |------------>| AXI         |--------->|                  |
 |                |  FCLK_CLK0  | Interconnect|          | conv_accel_top   |
 |  DDR           |             +-------------+          |                  |
 |   ^            |  S_AXI_HP0  +-------------+  m_axi   |  aclk, aresetn   |
 |   +------------|<------------| AXI         |<---------|                  |
 +----------------+             | Interconnect|          +------------------+
                                +-------------+     Processor System Reset -> aresetn
```

## 0. Before Vivado

- [ ] **Set the board in the RTL.** `vhdl/src/camus_pkg.vhd` has `BOARD := ULTRA96` today. For the ZedBoard it must be `ZEDBOARD` (64-bit data port, AXI3 burst limit 16). With the wrong value the master is 128 bit wide and does not fit the 64-bit HP port.
- [ ] Re-run the simulation with that setting: `vhdl/tests/run_axi_regression.sh zedboard` (needs the GHDL LLVM/GCC backend), or run `tb_conv_accel_top` by hand as in its header.
- [ ] `ghdl --synth --std=08 conv_accel_top` runs through (it does for both boards as of 2026-11-10, after the lane loop in `conv_engine_v1`). This is no proof that Vivado accepts the code, only a first filter.

## 1. Add the RTL

All sources are VHDL-2008 (the testbenches and the aggregates in `axi_lite_regs` need it).

- [ ] Add the files of `vhdl/src/` in this set, nothing from `vhdl/tests/`: `camus_pkg`, `axi_pkg`, `compute-engine/{loop_nest,addr_gen,mac_int8,requant,conv_core_v1,conv_engine_v1}`, `interface/{axi_lite_regs,sync_fifo,axi_skid,axi_master_rd,axi_master_wr,axi_ddr_master}`, `conv_accel_top`. `requant.vhd` is not used by v1, leaving it out is fine.
- [ ] Set the file type of all of them to **VHDL 2008** (Tcl: `set_property file_type {VHDL 2008} [get_files *.vhd]`). All go into library `work`.
- [ ] Top = `conv_accel_top`. Elaborate and check there are no errors. Watch for: record ports (none at the top), `shared variable` (only in the models), the `assert` statements (fine).

## 2. Make the top usable in the block design

Two ways, pick one. **Module reference** is quicker for a first try, **Package IP** is cleaner once it works.

**a) Module reference:** right click the block design, *Add Module*, choose `conv_accel_top`. Vivado infers the two bus interfaces from the port names (`s_axi_*` is AXI4-Lite slave, `m_axi_*` is AXI4 master) *(check)*.

**b) Package IP:** *Tools > Create and Package New IP* from the project. Same inference, then in the packager: *Ports and Interfaces* shows the two interfaces, *File Groups* must list all VHDL files as VHDL 2008.

- [ ] Both interfaces are found: `s_axi` (AXI4-Lite, **slave**, 32 bit data, `G_LITE_ADDR_W` = 8 address bits) and `m_axi` (AXI4, **master**, `AXI_ADDR_W` = 32, data width 64 on the ZedBoard).
- [ ] `aclk` is the clock of **both** interfaces, `aresetn` is an **active-low** reset. If Vivado does not associate them by itself (typical warning: a bus interface without an associated clock, or an unknown `FREQ_HZ`), fix it in the packager (*Ports and Interfaces > clock > Associated Bus Interfaces = `s_axi:m_axi`*, reset polarity *ACTIVE_LOW*). For a module reference the same information can be put into the RTL as attributes on the ports, which are **not in the file yet and untested**:
  ```vhdl
  attribute X_INTERFACE_INFO : string;
  attribute X_INTERFACE_PARAMETER : string;
  attribute X_INTERFACE_INFO of aclk : signal is "xilinx.com:signal:clock:1.0 aclk CLK";
  attribute X_INTERFACE_PARAMETER of aclk : signal is "ASSOCIATED_BUSIF s_axi:m_axi, ASSOCIATED_RESET aresetn";
  attribute X_INTERFACE_INFO of aresetn : signal is "xilinx.com:signal:reset:1.0 aresetn RST";
  attribute X_INTERFACE_PARAMETER of aresetn : signal is "POLARITY ACTIVE_LOW";
  ```
- [ ] `m_axi` ID width is `G_ID_W` = 2 bits. The HP port has 6 ID bits *(check)*; a narrower master ID is normally fine, but look for a width warning.
- [ ] There is no `awprot`/`arprot` on `s_axi`, and no interrupt. Vivado leaves the optional signals unconnected, that is expected.

## 3. Block design

- [ ] **ZYNQ7 Processing System**. Apply the ZedBoard preset if the board files are installed, otherwise configure the DDR (DDR3, the ZedBoard part) and the MIO by hand *(check)*. A wrong DDR setting shows up as a PS that does not boot. Run *Run Block Automation* if offered.
- [ ] PS configuration:
  - [ ] *PS-PL Configuration > GP Master AXI Interface:* enable **M AXI GP0**.
  - [ ] *HP Slave AXI Interface:* enable **S AXI HP0**, data width **64** (must equal `AXI_DATA_W`).
  - [ ] *Clock Configuration > PL Fabric Clocks:* enable **FCLK_CLK0**. **Start at 100 MHz.** D5 asks for 200 MHz, but nobody has seen the timing report on this device yet; raise it after step 5.
- [ ] Add the accelerator (module or IP).
- [ ] **AXI Interconnect** between `M_AXI_GP0` and `s_axi`. The PS port is AXI3 with 32-bit data, the slave is AXI4-Lite, the interconnect converts *(check)*.
- [ ] **AXI Interconnect** (or SmartConnect) between `m_axi` and `S_AXI_HP0`. On the ZedBoard it converts AXI4 to AXI3 *(check)*; bursts are at most 16 beats, so it never has to split one.
- [ ] **Processor System Reset** with `slowest_sync_clk` = `FCLK_CLK0` and `ext_reset_in` = `FCLK_RESET0_N`. Its `peripheral_aresetn` goes to the accelerator's `aresetn` and to the interconnect resets.
- [ ] **One clock net** `FCLK_CLK0` to: `M_AXI_GP0_ACLK`, `S_AXI_HP0_ACLK`, `aclk`, both interconnects, the reset block. The accelerator has no clock-domain crossing, so all must be the same clock.
- [ ] **Address Editor** (*Window > Address Editor*):
  - [ ] `s_axi` gets a range, for example 4 KB or the default 64 KB (Vivado often proposes `0x43C0_0000` for the first GP0 slave *(check)*). **Write the base address down: it is the `--regs` value of `accel_probe`.** The registers occupy 0x00 to 0x44, the rest of the range reads 0.
  - [ ] `m_axi` must see the DDR through HP0 (segment `S_AXI_HP0_DDR_LOWOCM`, 512 MB at `0x0000_0000` on the ZedBoard *(check)*). If the DDR segment is not assigned the accelerator's reads hang or return errors.
- [ ] *Validate Design* has no errors. Read each warning, in particular about clock association, `FREQ_HZ` and ID width.
- [ ] *Create HDL Wrapper*, set it as top.

## 4. Build

- [ ] Run synthesis. Look at the messages for inferred latches, ignored attributes, and RAM inference of the FIFOs in the masters (GHDL reported block RAM style FIFOs of 130 and 144 bits; check how Vivado maps them, it should not use many BRAMs).
- [ ] Run implementation, then bitstream.
- [ ] Fill in the **results sheet** (section 7).

## 5. Timing and resources

- [ ] *Report Timing Summary:* WNS and TNS at 100 MHz. If WNS is positive with margin, try 150 and 200 MHz (change `FCLK_CLK0`, rebuild). The 200 MHz of D5 is unconfirmed on the XC7Z020.
- [ ] *Report Utilization:* DSP count (v1 has one MAC and the requant is not used, expect very few DSPs), BRAM, LUT.
- [ ] Write the final clock into the performance notes: the v1 estimate of about 22 clocks per MAC from simulation gives about 0.8 G clocks per frame, so the frame time follows directly from the clock (about 8 s at 100 MHz, 4 s at 200 MHz; arithmetic from simulation numbers, not a measurement).

## 6. To the board

- [ ] Export the bitstream (`.bit`; for loading from Linux with `xdevcfg` it usually has to be converted to a `.bin` with bootgen *(check)*, the loading method depends on the OS image, D4).
- [ ] Reserve DDR for the DMA buffers: the kernel must not use it. Example for a 512 MB ZedBoard *(check)*: boot with `mem=496M`, which leaves `0x1F00_0000` to `0x1FFF_FFFF` free, then use `--mem 0x1F000000:0x1000000`. About 1 MB is enough.
- [ ] Load the bitstream, check the PL clock runs. Typical first sign of a wrong address map or a missing clock: reading a register hangs the CPU.
- [ ] Run, in this order (commands in the [README](../../README.md#arm-side-of-the-accelerator-c)): `accel_probe`, `accel_golden` for the small layers first (`b3sc`, `b2sc`, `stem`) and then all nine, then `camus_accel`. Copy `build/export/golden/f000` to the board by hand, `make package` leaves it out.

## 7. Results sheet (fill in)

| Item | Value |
|---|---|
| Vivado version | |
| `BOARD` in `camus_pkg` | |
| PS board preset / DDR settings | |
| `FCLK_CLK0` | |
| WNS / TNS | |
| DSP / BRAM / LUT | |
| `s_axi` base address | |
| DDR segment seen by `m_axi` | |
| HP0 data width, converter inserted (AXI3) | |
| Reserved DMA range | |
| Bitstream load method | |
| `accel_probe` | |
| `accel_golden` layers passed | |
| `camus_accel` bit-exact / frame time | |

## 8. Facts to look up (from [axi-ddr-master.md section 3.4](axi-ddr-master.md#34-check-on-the-zedboard-facts-not-yet-confirmed))

- [ ] The HP port protocol (AXI3), width (64) and ID bits (6), and whether Vivado inserts the AXI4 to AXI3 converter by itself.
- [ ] The maximum HP port clock, and whether 200 MHz closes timing on the XC7Z020.
- [ ] Whether HP0 and HP1 share a DDR controller port (matters for a second HP port later, TD-2).
- [ ] The DDR size and its address range as seen from the HP ports.
