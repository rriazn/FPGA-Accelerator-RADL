# VHDL modules: purpose and interfaces

Companion to `architecture-spec.md` (behavior, layout, registers), `architecture-diagram.md` (block diagrams) and `vhdl-accelerator-tasks.md` (task IDs). All module names, port names and widths here are **proposals** to be fixed in task 0.3 and then kept stable, because testbenches and the other owner's code depend on them.

## Conventions

- **Naming (decided):** every port starts with `i_` (input) or `o_` (output), for example `i_clk`, `o_acc`. Every signal inside an architecture starts with `s_`, for example `s_acc`. Record fields (`cfg.c`) are not prefixed.
- `ieee.numeric_std` (`signed`/`unsigned`), no `std_logic_arith`. Synchronous logic, one clock `i_clk` (200 MHz, D5).
- **Reset (decided):** one port `i_rst`, **synchronous** and **active-high** (reset while `i_rst = '1'`), used by every module. Control state (valid flags, FSM states, counters) must always be reset. Datapath registers need not be, because the next valid input overwrites them; `mac_int8` resets its accumulator anyway, which is harmless and maps to the synchronous reset of the DSP48E2. AXI resets are active-low (`aresetn`), so `conv_accel_top` inverts the AXI reset once before it reaches the internal modules.
- **AXI bus ports (open):** the AXI4-Lite and AXI4 ports are written below as comments with their standard names (`s_axi_*`, `m_axi_*`). Vivado infers the interface from these names, so prefixing them with `i_`/`o_` may stop it from recognizing the bundle; settle this when the block design is made (task 3.3).
- Between internal blocks: **valid/ready handshake** (a transfer happens in a cycle where `valid` and `ready` are both 1). Blocks that cannot stall (the PE pipeline) say so and use only `valid`.
- Common generics, defined once in `camus_pkg.vhd`: `LANES = 16`, `ACT_W = 8`, `ACC_W = 32`, `AXI_DATA_W = 128`, `AXI_ADDR_W = 32`. Bus widths depend on the block design (D4); keep them as generics, not literals.
- Addresses to the AXI master are **byte addresses**. Element addresses (from the layout formula in the spec) are converted to byte addresses in `addr_gen`.
- Each module gets a testbench against the golden vectors (task 0.5) as noted per module.

## Module overview

**Decided:** synthesizable modules related to the compute engine go in `vhdl/src/compute-engine/` (file names below are relative to it). Simulation-only files and testbenches go in `vhdl/tests/`, packages go in `vhdl/src/`.

| Module | File | Used in | Task | Owner area |
|---|---|---|---|---|
| `camus_pkg` | `camus_pkg.vhd` | all | 0.3 | Core, Sys |
| `axi_lite_regs` | `regs.vhd` | v1, target | 1.4 | Sys |
| `loop_nest` | `loop_nest.vhd` | v1 | 1.3 | Core |
| `addr_gen` | `addrgen.vhd` | v1, target | 1.3 | Core |
| `axi_master_rd` | `axi_master_rd.vhd` | v1, target | 2.3 | Core, Sys |
| `axi_master_wr` | `axi_master_wr.vhd` | v1, target | 2.3 | Core, Sys |
| `mac_int8` | `mac_int8.vhd` | v1 | 1.1 | Core |
| `conv_engine_v1` | `conv_v1.vhd` | v1 | 2.1 | Core |
| `conv_accel_top` | `top.vhd` | v1, target | 2.3 | Core, Sys |
| `weight_store` | `weight_store.vhd` | target | 4.1 | Core |
| `weight_loader` | `weight_loader.vhd` | target | 4.1 | Core |
| `line_buffer` | `line_buffer.vhd` | target | 4.1 | Core |
| `window_gen` | `window_gen.vhd` | target | 4.2 | Core |
| `pe_lane` | `pe_lane.vhd` | target | 4.2 | Core |
| `pe_array` | `pe_array.vhd` | target | 4.3, 4.4 | Core |
| `layer_sequencer` | `layer_seq.vhd` | target | 4.1 to 4.3 | Core |
| `requant` | `requant.vhd` | 4.6 | 1.2 | Core |
| `writeback` | `writeback.vhd` | target, 4.6 | 1.5 | Core |
| `skip_reader` | `skip_reader.vhd` | 4.6 | 1.5 | Core |
| simulation only: `axi_mem_model`, `golden_io`, testbenches | `vhdl/tests/` | all | 0.5, 2.2 | Core, Pipe |

"v1" = hardware baseline (Phase 2). "target" = steps 4.1 to 4.4. "4.6" = Fusion. A module used in v1 is reused by the later versions unless a row says otherwise (`conv_engine_v1` is replaced by `layer_sequencer` + `pe_array`).

---

## Shared

### `camus_pkg`

Constants, types and helper functions shared by all modules. The current version is `vhdl/src/camus_pkg.vhd`.

```vhdl
constant LANES      : natural := 16;
constant ACT_W      : natural := 8;
constant ACC_W      : natural := 32;
constant MULT_W     : natural := 16;     -- D6
subtype  act_t is signed(ACT_W-1 downto 0);
subtype  acc_t is signed(ACC_W-1 downto 0);

type layer_cfg_t is record               -- written by the ARM through axi_lite_regs
  c, k, h, w       : natural;            -- input channels, output channels, input size
  fy, fx           : natural range 1 to 7;
  stride, pad      : natural range 0 to 7;
  in_lanes, out_lanes : natural range 1 to LANES;   -- L of the layout (1 or 16)
  in_base, w_base, b_base, out_base : unsigned(AXI_ADDR_W-1 downto 0);
  -- 4.6 only: m0, shift, relu_en, skip_en, skip_base, skip_m0, skip_shift
end record;

function out_dim(i, f, s, p : natural) return natural;       -- (i + 2p - f) / s + 1
function elem_addr(c, y, x, h, w, l : natural) return natural;   -- the layout formula, l = lanes (VHDL is case-insensitive, so not "lanes")
```

Ranges (kernel and stride limits) are open; 3x3 and 1x1 with stride 1 and 2 are the minimum.

---

## Control and interface

### `axi_lite_regs` (task 1.4)

AXI4-Lite slave. Holds the layer registers of the spec (section 4), decodes writes into `o_cfg`, pulses `o_start`, and exposes status and the cycle count.

```vhdl
entity axi_lite_regs is
  port (
    i_clk, i_rst : in std_logic;
    -- AXI4-Lite slave: s_axi_awaddr/awvalid/awready, wdata/wstrb/wvalid/wready,
    --   bresp/bvalid/bready, araddr/arvalid/arready, rdata/rresp/rvalid/rready
    -- to the accelerator
    o_cfg       : out layer_cfg_t;
    o_start     : out std_logic;                 -- one-cycle pulse when CTRL.start is written
    o_soft_rst  : out std_logic;
    i_busy, i_done, i_error : in std_logic;      -- shown in STATUS; done sticky until next start
    i_cycles    : in unsigned(31 downto 0)       -- shown in CYCLES
  );
end entity;
```

Writing `start` while `busy` sets `error`. `done` is cleared on `start`. Optional `o_irq` output (open point 4 in the spec).

### `conv_accel_top` (task 2.3)

Top level of the IP: clock, reset, the AXI-Lite slave and the AXI master port. Instantiates the modules of the active version.

```vhdl
entity conv_accel_top is
  port (
    i_clk, i_rst : in std_logic;
    -- s_axi_*  : AXI4-Lite slave  (ARM control)
    -- m_axi_*  : AXI4 master, AXI_DATA_W wide (DDR access, one bundle with read and write channels)
    o_irq       : out std_logic                  -- optional
  );
end entity;
```

### `loop_nest` (task 1.3, v1)

Runtime-bounded nested counters that step through the iteration space of a layer. Generic "odometer" with a handshake.

```vhdl
entity loop_nest is
  port (
    i_clk, i_rst : in std_logic;
    i_cfg       : in layer_cfg_t;
    i_start     : in std_logic;
    i_step      : in std_logic;                  -- advance to the next iteration
    o_k, o_oy, o_ox, o_c, o_fy, o_fx : out natural;   -- current indices, innermost loop is fx
    o_first_mac, o_last_mac  : out std_logic;    -- first / last iteration of the current output element
    o_last_output            : out std_logic;    -- last output element of the layer
    o_running                : out std_logic
  );
end entity;
```

Order for v1: `k, oy, ox, c, fy, fx` (output element outermost, so the accumulator completes before the next). The target design replaces this with `layer_sequencer`.

Behavior (implemented in `loop_nest.vhd`, tested by `tb_loop_nest.vhd`): `i_start` is ignored while running. The loop limits (`OH`, `OW` from `out_dim`, and `k`, `c`, `fy`, `fx`) are latched at start, so `i_cfg` may change during the run. The outputs show the term that has not been accepted yet; with `i_step = 1` the nest advances at the next clock edge, with `i_step = 0` it waits. `o_first_mac`, `o_last_mac` and `o_last_output` are 0 while `o_running = 0`. The config must be valid (all sizes at least 1, `h + 2*pad >= fy`), otherwise the natural subtraction fails.

### `addr_gen` (task 1.3)

Combinational (or one pipeline stage) address calculation from loop indices. Implements the layout formula with L, symmetric zero padding and stride.

```vhdl
entity addr_gen is
  port (
    i_cfg        : in layer_cfg_t;
    i_k, i_oy, i_ox, i_c, i_fy, i_fx : in natural;
    o_x_addr     : out unsigned(AXI_ADDR_W-1 downto 0);   -- byte address of x[c][iy][ix]
    o_x_valid    : out std_logic;                          -- 0 if (iy, ix) is outside the input: use 0, no read
    o_w_addr     : out unsigned(AXI_ADDR_W-1 downto 0);   -- byte address of w[k][c][fy][fx]
    o_b_addr     : out unsigned(AXI_ADDR_W-1 downto 0);   -- byte address of bias[k]
    o_out_addr   : out unsigned(AXI_ADDR_W-1 downto 0)    -- byte address of acc[k][oy][ox] (int32, layout with out_lanes)
  );
end entity;
```

Where `iy = oy*stride - pad + fy`, `ix = ox*stride - pad + fx`. Test: exhaustive comparison with a Python or C model of the same formulas for ResNet-8 shapes plus the random layers from task 0.5.

### `axi_master_rd` and `axi_master_wr` (task 2.3)

Read and write channels of the AXI master, with a simple command interface so the engine does not deal with AXI details. v1 uses single-beat commands. Bursts (`len > 1`) are added with the line buffers in 4.1.

```vhdl
entity axi_master_rd is
  port (
    i_clk, i_rst : in std_logic;
    i_cmd_valid : in std_logic;  o_cmd_ready : out std_logic;
    i_cmd_addr  : in unsigned(AXI_ADDR_W-1 downto 0);        -- byte address, aligned to the burst start
    i_cmd_len   : in unsigned(7 downto 0);                    -- beats minus 1 (0 in v1)
    o_rsp_valid : out std_logic; i_rsp_ready : in std_logic;
    o_rsp_data  : out std_logic_vector(AXI_DATA_W-1 downto 0);
    o_rsp_last  : out std_logic;
    o_rsp_error : out std_logic                               -- AXI RRESP /= OKAY
    -- m_axi_ar* and m_axi_r* signals
  );
end entity;

entity axi_master_wr is
  port (
    i_clk, i_rst : in std_logic;
    i_cmd_valid : in std_logic;  o_cmd_ready : out std_logic;
    i_cmd_addr  : in unsigned(AXI_ADDR_W-1 downto 0);
    i_cmd_len   : in unsigned(7 downto 0);
    i_wdata_valid : in std_logic; o_wdata_ready : out std_logic;
    i_wdata     : in std_logic_vector(AXI_DATA_W-1 downto 0);
    i_wstrb     : in std_logic_vector(AXI_DATA_W/8-1 downto 0);   -- byte enables: v1 writes 4 bytes inside a wide beat
    i_wlast     : in std_logic;
    o_done      : out std_logic;                                   -- write response received
    o_error     : out std_logic                                    -- AXI BRESP /= OKAY
    -- m_axi_aw*, m_axi_w* and m_axi_b* signals
  );
end entity;
```

The two entities share the `m_axi` port bundle at the top level. The master must not cross 4 KB boundaries within a burst (AXI rule); the address generator and the loader are responsible for splitting commands.

---

## v1 compute

### `mac_int8` (task 1.1)

Signed int8 x int8 multiply-accumulate into an int32 accumulator, written so the synthesizer infers a DSP48E2 (multiplier, adder and accumulator register in one block). `i_rst` clears the accumulator and `o_acc_valid`. The accumulator is cleared although `i_first` would overwrite it anyway, which is harmless and maps to the DSP's synchronous reset.

```vhdl
entity mac_int8 is
  generic ( PIPE : natural := 1 );                  -- extra pipeline registers (4.4), optional for v1
  port (
    i_clk, i_rst : in std_logic;
    i_en        : in std_logic;                      -- consume a, b this cycle
    i_first     : in std_logic;                      -- start a new sum: acc <= bias + a*b
    i_last      : in std_logic;                      -- this term completes the sum
    i_bias      : in acc_t;
    i_a, i_b    : in act_t;                          -- x and w, signed
    o_acc       : out acc_t;                         -- running sum
    o_acc_valid : out std_logic                      -- one cycle, o_acc holds a completed sum
  );
end entity;
```

Latency is one clock: `o_acc` and `o_acc_valid` change on the edge that consumes the inputs. `o_acc_valid` is registered `i_en and i_last`, so it is 1 for exactly one cycle after the last term, and 0 when `i_en = 0`. The unit testbench is `vhdl/tests/unit/compute-engine/tb_mac_int8.vhd`. Bit-exact: int32 wrap-around must not occur for valid layers (observed |acc| < 2^17, see spec section 5).

### `conv_engine_v1` (task 2.1)

Sequences one MAC at a time over the whole layer. For each iteration it reads `x` and `w` (skipping the read and using 0 when `o_x_valid = 0`, still with `i_en = 1` so that `i_first` loads the bias), feeds `mac_int8`, and at the end of each output element writes the int32 result.

```vhdl
entity conv_engine_v1 is
  port (
    i_clk, i_rst : in std_logic;
    i_cfg       : in layer_cfg_t;
    i_start     : in std_logic;
    o_busy, o_done, o_error : out std_logic;
    o_cycles    : out unsigned(31 downto 0);         -- counts clk while busy
    -- read command and response ports of axi_master_rd (x, w, bias)
    -- write command and data ports of axi_master_wr (acc)
  );
end entity;
```

Details: selects the byte inside the wide AXI beat from the low address bits; reads the bias once per output element (v1 does not cache it); writes with `wstrb` set to the 4 bytes of the int32 inside the wide beat. Instantiates `loop_nest`, `addr_gen` and `mac_int8`.

---

## Target design (steps 4.1 to 4.4)

### `weight_store` (4.1)

Banked on-chip memory for weights and bias: one bank per output lane, so all weights of a given input channel for 16 output channels are read in a single cycle (16 x 9 x 8 = 1,152 bit).

```vhdl
entity weight_store is
  port (
    i_clk : in std_logic;
    -- load side (from weight_loader)
    i_wr_en    : in std_logic;
    i_wr_addr  : in unsigned(...);                   -- word address, width from the capacity (76,432 B + bias)
    i_wr_data  : in std_logic_vector(AXI_DATA_W-1 downto 0);
    -- compute side
    i_rd_kblk  : in unsigned(...);                   -- output-channel block (K/16)
    i_rd_c     : in unsigned(...);                   -- input channel
    o_rd_w     : out std_logic_vector(LANES*9*ACT_W-1 downto 0);   -- w[k..k+15][c][fy][fx]
    o_rd_bias  : out std_logic_vector(LANES*ACC_W-1 downto 0)      -- bias[k..k+15]
  );
end entity;
```

Read latency is fixed (one or two clocks, a generic). Kernels smaller than 3x3 use the first taps and leave the rest zero. Open: the exact word layout in the banks follows from the BRAM port widths (D4, datasheet).

### `weight_loader` (4.1)

Reads the weight and bias image from DDR with `axi_master_rd` bursts and writes it into `weight_store`. Triggered by a layer or network start (open point 2 in the spec).

```vhdl
entity weight_loader is
  port (
    i_clk, i_rst : in std_logic;
    i_cfg       : in layer_cfg_t;
    i_load      : in std_logic;
    o_loaded    : out std_logic;
    -- read command and response ports of axi_master_rd
    -- write port of weight_store
  );
end entity;
```

### `line_buffer` (4.1)

Holds `FY` rows of the input, all channel blocks, in BRAM. Written from the AXI read stream, read in parallel for the rows of one column.

```vhdl
entity line_buffer is
  port (
    i_clk : in std_logic;
    i_wr_en    : in std_logic;
    i_wr_row   : in unsigned(...);  i_wr_col : in unsigned(...);  i_wr_cblk : in unsigned(...);
    i_wr_data  : in std_logic_vector(LANES*ACT_W-1 downto 0);    -- 16 channels of one pixel
    i_rd_col   : in unsigned(...);  i_rd_cblk : in unsigned(...);
    o_rd_rows  : out std_logic_vector(3*LANES*ACT_W-1 downto 0)  -- the FY rows (3 here) at that column
  );
end entity;
```

Capacity C x W x FY: at most 2,688 B for our network (spec, section 6.2). Generic maximum capacity for the runtime-sized layers.

### `window_gen` (4.2)

Turns the column stream from `line_buffer` into a 3x3 window of **one input channel** per cycle, handling stride and zero padding at the borders.

```vhdl
entity window_gen is
  port (
    i_clk, i_rst : in std_logic;
    i_cfg       : in layer_cfg_t;
    i_col_valid : in std_logic;  o_col_ready : out std_logic;
    i_col_data  : in std_logic_vector(3*LANES*ACT_W-1 downto 0);
    i_lane_sel  : in unsigned(3 downto 0);            -- which channel of the block this cycle
    o_win       : out std_logic_vector(9*ACT_W-1 downto 0);
    o_win_valid : out std_logic
  );
end entity;
```

### `pe_lane` (4.2)

One output channel: 9 MACs, an adder tree over the 9 products, and an accumulator (int32) that sums over the input channels.

```vhdl
entity pe_lane is
  generic ( PIPE : natural := 1 );
  port (
    i_clk, i_rst : in std_logic;
    i_en        : in std_logic;
    i_first, i_last : in std_logic;                   -- first / last input channel of this output pixel
    i_bias      : in acc_t;
    i_win       : in std_logic_vector(9*ACT_W-1 downto 0);
    i_wgt       : in std_logic_vector(9*ACT_W-1 downto 0);
    o_acc       : out acc_t;
    o_acc_valid : out std_logic                       -- completed sum, one cycle after last (plus pipeline)
  );
end entity;
```

### `pe_array` (4.3, pipelined in 4.4)

16 `pe_lane`s sharing one window and with individual weights, bias and accumulators.

```vhdl
entity pe_array is
  generic ( PIPE : natural := 2 );
  port (
    i_clk, i_rst : in std_logic;
    i_en, i_first, i_last : in std_logic;
    i_win       : in std_logic_vector(9*ACT_W-1 downto 0);          -- shared by all lanes
    i_wgt       : in std_logic_vector(LANES*9*ACT_W-1 downto 0);
    i_bias      : in std_logic_vector(LANES*ACC_W-1 downto 0);
    o_acc       : out std_logic_vector(LANES*ACC_W-1 downto 0);
    o_acc_valid : out std_logic
  );
end entity;
```

Fixed latency, no back-pressure: the sequencer must only issue when the write-back can take the result (or the write-back has a small FIFO).

### `layer_sequencer` (4.1 to 4.3)

Replaces `conv_engine_v1`: runs the layer, drives the loader, line buffers, window generator and array, and tracks the cycle count.

```vhdl
entity layer_sequencer is
  port (
    i_clk, i_rst : in std_logic;
    i_cfg       : in layer_cfg_t;
    i_start     : in std_logic;
    o_busy, o_done, o_error : out std_logic;
    o_cycles    : out unsigned(31 downto 0);
    -- control signals to weight_loader, line_buffer fill (axi_master_rd commands),
    --   window_gen, pe_array (en, first, last, weight and bias addresses), writeback
  );
end entity;
```

Loop order (open point 3 in the spec): proposal `oy, ox, kblk, c`, so each input pixel column is read from DDR once.

---

## Write-back and Fusion (1.2, 1.5, 4.6)

### `writeback` (1.5)

Packs the 16 accumulators of one output pixel into a write stream for `axi_master_wr`. In v1 and the target design this is int32 x 16 = 64 B. With Fusion it contains requant, ReLU/clip and the residual add and writes int8 x 16 = 16 B.

```vhdl
entity writeback is
  generic ( FUSED : boolean := false );               -- true from step 4.6
  port (
    i_clk, i_rst : in std_logic;
    i_cfg       : in layer_cfg_t;
    i_pix_valid : in std_logic;  o_pix_ready : out std_logic;
    i_pix_acc   : in std_logic_vector(LANES*ACC_W-1 downto 0);
    i_pix_oy, i_pix_ox, i_pix_kblk : in unsigned(...);
    -- FUSED only: skip_valid/skip_data from skip_reader
    -- write command and data ports of axi_master_wr
    o_pix_done  : out std_logic
  );
end entity;
```

### `requant` (1.2)

`y = (acc * m0 + 2^(shift-1)) >> shift`, round half up, arithmetic shift. Two outputs: the **wide** result (needed for the residual add, see below) and the result clipped to 0..127.

```vhdl
entity requant is
  generic ( PIPE : natural := 2 );
  port (
    i_clk, i_rst : in std_logic;
    i_valid     : in std_logic;
    i_acc       : in acc_t;
    i_m0        : in unsigned(MULT_W-1 downto 0);
    i_shift     : in unsigned(5 downto 0);            -- 16 to 26 in the current export
    o_valid     : out std_logic;
    o_y_wide    : out signed(ACC_W-1 downto 0);       -- unclipped
    o_y_relu8   : out act_t                           -- clipped to 0..127
  );
end entity;
```

Bit-exact to `requant()` in `quantize.py` (tested against the golden int32 and int8 vectors). One multiplier infers one DSP48E2 with the rounding constant on the C port.

### `skip_reader` (1.5, 4.6)

Reads the skip tensor from DDR in step with the output pixels: the block input for the identity shortcut of block 1, or the requantized shortcut-convolution result for blocks 2 and 3. Provides it to `writeback`.

```vhdl
entity skip_reader is
  port (
    i_clk, i_rst : in std_logic;
    i_cfg       : in layer_cfg_t;
    i_req_valid : in std_logic;  o_req_ready : out std_logic;
    i_req_oy, i_req_ox, i_req_kblk : in unsigned(...);
    o_skip_valid : out std_logic; i_skip_ready : in std_logic;
    o_skip_data  : out std_logic_vector(LANES*ACT_W-1 downto 0)   -- or wider, see open point 6
    -- read command and response ports of axi_master_rd
  );
end entity;
```

The width of `o_skip_data` depends on open point 6: if the requantized shortcut must stay wider than int8, this becomes 16-bit or 32-bit lanes.

---

## Simulation only

- **`axi_mem_model`**: AXI4 slave memory behind the AXI master port, preloaded from the exported files, with configurable latency and back-pressure, and a dump of its contents at the end.
- **`golden_io`**: reads the golden vectors of task 0.5 with `std.textio` (activations, weights, bias, expected accumulators and outputs) and compares them against the design's results, reporting the first mismatch.
- **Testbenches**: one per module above (`tb_<module>.vhd`), then a layer-level testbench driving the full top level through its AXI-Lite port (task 2.2).

## Build order

```
camus_pkg ─┬─ loop_nest ─ addr_gen ─┐
           ├─ axi_lite_regs         ├─ conv_engine_v1 ─ conv_accel_top   (v1, tasks 1.x, 2.x)
           ├─ axi_master_rd/wr ─────┤
           └─ mac_int8 ─────────────┘

v1 working ─ weight_store + weight_loader + line_buffer (4.1) ─ window_gen + pe_lane (4.2)
           ─ pe_array + layer_sequencer (4.3) ─ pipelining (4.4)
           ─ requant + skip_reader + writeback FUSED (4.6)
```
