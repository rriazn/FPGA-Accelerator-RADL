# VHDL modules: purpose and interfaces

Companion to `architecture-spec.md` (behavior, layout, registers), `architecture-diagram.md` (block diagrams) and `vhdl-accelerator-tasks.md` (task IDs). All module names, port names and widths here are **proposals** to be fixed in task 0.3 and then kept stable, because testbenches and the other owner's code depend on them.

## Conventions (proposal)

- `ieee.numeric_std` (`signed`/`unsigned`), no `std_logic_arith`. Synchronous logic, one clock `clk` (200 MHz, D5), active-low synchronous reset `rstn` (matches AXI).
- Between internal blocks: **valid/ready handshake** (a transfer happens in a cycle where `valid` and `ready` are both 1). Blocks that cannot stall (the PE pipeline) say so and use only `valid`.
- Common generics, defined once in `camus_pkg.vhd`: `LANES = 16`, `ACT_W = 8`, `ACC_W = 32`, `AXI_DATA_W = 128`, `AXI_ADDR_W = 32`. Bus widths depend on the block design (D4); keep them as generics, not literals.
- Addresses to the AXI master are **byte addresses**. Element addresses (from the layout formula in the spec) are converted to byte addresses in `addr_gen`.
- Each module gets a testbench against the golden vectors (task 0.5) as noted per module.

## Module overview

| Module | File | Used in | Task | Owner area |
|---|---|---|---|---|
| `camus_pkg` | `camus_pkg.vhd` | all | 0.3 | Core, Sys |
| `axi_lite_regs` | `regs.vhd` | v1, target | 1.4 | Sys |
| `loop_nest` | `loop_nest.vhd` | v1 | 1.3 | Core |
| `addr_gen` | `addrgen.vhd` | v1, target | 1.3 | Core |
| `axi_master_rd` | `axi_master_rd.vhd` | v1, target | 2.3 | Core, Sys |
| `axi_master_wr` | `axi_master_wr.vhd` | v1, target | 2.3 | Core, Sys |
| `mac_int8` | `mac.vhd` | v1 | 1.1 | Core |
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
| simulation only: `axi_mem_model`, `golden_io`, testbenches | `sim/` | all | 0.5, 2.2 | Core, Pipe |

"v1" = hardware baseline (Phase 2). "target" = steps 4.1 to 4.4. "4.6" = Fusion. A module used in v1 is reused by the later versions unless a row says otherwise (`conv_engine_v1` is replaced by `layer_sequencer` + `pe_array`).

---

## Shared

### `camus_pkg`

Constants, types and helper functions shared by all modules.

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
function elem_addr(c, y, x, h, w, lanes : natural) return natural;   -- the layout formula
```

Ranges (kernel and stride limits) are open; 3x3 and 1x1 with stride 1 and 2 are the minimum.

---

## Control and interface

### `axi_lite_regs` (task 1.4)

AXI4-Lite slave. Holds the layer registers of the spec (section 4), decodes writes into `cfg`, pulses `start`, and exposes status and the cycle count.

```vhdl
entity axi_lite_regs is
  port (
    clk, rstn : in std_logic;
    -- AXI4-Lite slave: s_axi_awaddr/awvalid/awready, wdata/wstrb/wvalid/wready,
    --   bresp/bvalid/bready, araddr/arvalid/arready, rdata/rresp/rvalid/rready
    -- to the accelerator
    cfg       : out layer_cfg_t;
    start     : out std_logic;                 -- one-cycle pulse when CTRL.start is written
    soft_rst  : out std_logic;
    busy, done, error : in std_logic;          -- shown in STATUS; done sticky until next start
    cycles    : in unsigned(31 downto 0)       -- shown in CYCLES
  );
end entity;
```

Writing `start` while `busy` sets `error`. `done` is cleared on `start`. Optional `irq` output (open point 4 in the spec).

### `conv_accel_top` (task 2.3)

Top level of the IP: clock, reset, the AXI-Lite slave and the AXI master port. Instantiates the modules of the active version.

```vhdl
entity conv_accel_top is
  port (
    clk, rstn : in std_logic;
    -- s_axi_*  : AXI4-Lite slave  (ARM control)
    -- m_axi_*  : AXI4 master, AXI_DATA_W wide (DDR access, one bundle with read and write channels)
    irq       : out std_logic                  -- optional
  );
end entity;
```

### `loop_nest` (task 1.3, v1)

Runtime-bounded nested counters that step through the iteration space of a layer. Generic "odometer" with a handshake.

```vhdl
entity loop_nest is
  port (
    clk, rstn : in std_logic;
    cfg       : in layer_cfg_t;
    start     : in std_logic;
    step      : in std_logic;                  -- advance to the next iteration
    k, oy, ox, c, fy, fx : out natural;        -- current indices, innermost loop is fx
    first_mac, last_mac  : out std_logic;      -- first / last iteration of the current output element
    last_output          : out std_logic;      -- last output element of the layer
    running              : out std_logic
  );
end entity;
```

Order for v1: `k, oy, ox, c, fy, fx` (output element outermost, so the accumulator completes before the next). The target design replaces this with `layer_sequencer`.

### `addr_gen` (task 1.3)

Combinational (or one pipeline stage) address calculation from loop indices. Implements the layout formula with L, symmetric zero padding and stride.

```vhdl
entity addr_gen is
  port (
    cfg        : in layer_cfg_t;
    k, oy, ox, c, fy, fx : in natural;
    x_addr     : out unsigned(AXI_ADDR_W-1 downto 0);   -- byte address of x[c][iy][ix]
    x_valid    : out std_logic;                          -- 0 if (iy, ix) is outside the input: use 0, no read
    w_addr     : out unsigned(AXI_ADDR_W-1 downto 0);   -- byte address of w[k][c][fy][fx]
    b_addr     : out unsigned(AXI_ADDR_W-1 downto 0);   -- byte address of bias[k]
    out_addr   : out unsigned(AXI_ADDR_W-1 downto 0)    -- byte address of acc[k][oy][ox] (int32, layout with out_lanes)
  );
end entity;
```

Where `iy = oy*stride - pad + fy`, `ix = ox*stride - pad + fx`. Test: exhaustive comparison with a Python or C model of the same formulas for ResNet-8 shapes plus the random layers from task 0.5.

### `axi_master_rd` and `axi_master_wr` (task 2.3)

Read and write channels of the AXI master, with a simple command interface so the engine does not deal with AXI details. v1 uses single-beat commands. Bursts (`len > 1`) are added with the line buffers in 4.1.

```vhdl
entity axi_master_rd is
  port (
    clk, rstn : in std_logic;
    cmd_valid : in std_logic;  cmd_ready : out std_logic;
    cmd_addr  : in unsigned(AXI_ADDR_W-1 downto 0);        -- byte address, aligned to the burst start
    cmd_len   : in unsigned(7 downto 0);                    -- beats minus 1 (0 in v1)
    rsp_valid : out std_logic; rsp_ready : in std_logic;
    rsp_data  : out std_logic_vector(AXI_DATA_W-1 downto 0);
    rsp_last  : out std_logic;
    rsp_error : out std_logic                               -- AXI RRESP /= OKAY
    -- m_axi_ar* and m_axi_r* signals
  );
end entity;

entity axi_master_wr is
  port (
    clk, rstn : in std_logic;
    cmd_valid : in std_logic;  cmd_ready : out std_logic;
    cmd_addr  : in unsigned(AXI_ADDR_W-1 downto 0);
    cmd_len   : in unsigned(7 downto 0);
    wdata_valid : in std_logic; wdata_ready : out std_logic;
    wdata     : in std_logic_vector(AXI_DATA_W-1 downto 0);
    wstrb     : in std_logic_vector(AXI_DATA_W/8-1 downto 0);   -- byte enables: v1 writes 4 bytes inside a wide beat
    wlast     : in std_logic;
    done      : out std_logic;                                   -- write response received
    error     : out std_logic                                    -- AXI BRESP /= OKAY
    -- m_axi_aw*, m_axi_w* and m_axi_b* signals
  );
end entity;
```

The two entities share the `m_axi` port bundle at the top level. The master must not cross 4 KB boundaries within a burst (AXI rule); the address generator and the loader are responsible for splitting commands.

---

## v1 compute

### `mac_int8` (task 1.1)

Signed int8 x int8 multiply-accumulate into an int32 accumulator, written so the synthesizer infers a DSP48E2 (multiplier, adder and accumulator register in one block).

```vhdl
entity mac_int8 is
  generic ( PIPE : natural := 1 );                  -- extra pipeline registers (4.4)
  port (
    clk, rstn : in std_logic;
    en        : in std_logic;                        -- consume a, b this cycle
    first     : in std_logic;                        -- start a new sum: acc <= bias + a*b
    bias      : in acc_t;
    a, b      : in act_t;                            -- x and w, signed
    acc       : out acc_t;                           -- running sum
    acc_valid : out std_logic                        -- acc holds a completed sum (see last)
  );
end entity;
```

`last` is tracked by the caller and delayed alongside the data. Bit-exact: int32 wrap-around must not occur for valid layers (observed |acc| < 2^17, see spec section 5).

### `conv_engine_v1` (task 2.1)

Sequences one MAC at a time over the whole layer. For each iteration it reads `x` and `w` (skipping the read and using 0 when `x_valid = 0`), feeds `mac_int8`, and at the end of each output element writes the int32 result.

```vhdl
entity conv_engine_v1 is
  port (
    clk, rstn : in std_logic;
    cfg       : in layer_cfg_t;
    start     : in std_logic;
    busy, done, error : out std_logic;
    cycles    : out unsigned(31 downto 0);           -- counts clk while busy
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
    clk : in std_logic;
    -- load side (from weight_loader)
    wr_en    : in std_logic;
    wr_addr  : in unsigned(...);                     -- word address, width from the capacity (76,432 B + bias)
    wr_data  : in std_logic_vector(AXI_DATA_W-1 downto 0);
    -- compute side
    rd_kblk  : in unsigned(...);                     -- output-channel block (K/16)
    rd_c     : in unsigned(...);                     -- input channel
    rd_w     : out std_logic_vector(LANES*9*ACT_W-1 downto 0);   -- w[k..k+15][c][fy][fx]
    rd_bias  : out std_logic_vector(LANES*ACC_W-1 downto 0)      -- bias[k..k+15]
  );
end entity;
```

Read latency is fixed (one or two clocks, a generic). Kernels smaller than 3x3 use the first taps and leave the rest zero. Open: the exact word layout in the banks follows from the BRAM port widths (D4, datasheet).

### `weight_loader` (4.1)

Reads the weight and bias image from DDR with `axi_master_rd` bursts and writes it into `weight_store`. Triggered by a layer or network start (open point 2 in the spec).

```vhdl
entity weight_loader is
  port (
    clk, rstn : in std_logic;
    cfg       : in layer_cfg_t;
    load      : in std_logic;
    loaded    : out std_logic;
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
    clk : in std_logic;
    wr_en    : in std_logic;
    wr_row   : in unsigned(...);  wr_col : in unsigned(...);  wr_cblk : in unsigned(...);
    wr_data  : in std_logic_vector(LANES*ACT_W-1 downto 0);    -- 16 channels of one pixel
    rd_col   : in unsigned(...);  rd_cblk : in unsigned(...);
    rd_rows  : out std_logic_vector(3*LANES*ACT_W-1 downto 0)  -- the FY rows (3 here) at that column
  );
end entity;
```

Capacity C x W x FY: at most 2,688 B for our network (spec, section 6.2). Generic maximum capacity for the runtime-sized layers.

### `window_gen` (4.2)

Turns the column stream from `line_buffer` into a 3x3 window of **one input channel** per cycle, handling stride and zero padding at the borders.

```vhdl
entity window_gen is
  port (
    clk, rstn : in std_logic;
    cfg       : in layer_cfg_t;
    col_valid : in std_logic;  col_ready : out std_logic;
    col_data  : in std_logic_vector(3*LANES*ACT_W-1 downto 0);
    lane_sel  : in unsigned(3 downto 0);              -- which channel of the block this cycle
    win       : out std_logic_vector(9*ACT_W-1 downto 0);
    win_valid : out std_logic
  );
end entity;
```

### `pe_lane` (4.2)

One output channel: 9 MACs, an adder tree over the 9 products, and an accumulator (int32) that sums over the input channels.

```vhdl
entity pe_lane is
  generic ( PIPE : natural := 1 );
  port (
    clk, rstn : in std_logic;
    en        : in std_logic;
    first, last : in std_logic;                       -- first / last input channel of this output pixel
    bias      : in acc_t;
    win       : in std_logic_vector(9*ACT_W-1 downto 0);
    wgt       : in std_logic_vector(9*ACT_W-1 downto 0);
    acc       : out acc_t;
    acc_valid : out std_logic                         -- completed sum, one cycle after last (plus pipeline)
  );
end entity;
```

### `pe_array` (4.3, pipelined in 4.4)

16 `pe_lane`s sharing one window and with individual weights, bias and accumulators.

```vhdl
entity pe_array is
  generic ( PIPE : natural := 2 );
  port (
    clk, rstn : in std_logic;
    en, first, last : in std_logic;
    win       : in std_logic_vector(9*ACT_W-1 downto 0);          -- shared by all lanes
    wgt       : in std_logic_vector(LANES*9*ACT_W-1 downto 0);
    bias      : in std_logic_vector(LANES*ACC_W-1 downto 0);
    acc       : out std_logic_vector(LANES*ACC_W-1 downto 0);
    acc_valid : out std_logic
  );
end entity;
```

Fixed latency, no back-pressure: the sequencer must only issue when the write-back can take the result (or the write-back has a small FIFO).

### `layer_sequencer` (4.1 to 4.3)

Replaces `conv_engine_v1`: runs the layer, drives the loader, line buffers, window generator and array, and tracks the cycle count.

```vhdl
entity layer_sequencer is
  port (
    clk, rstn : in std_logic;
    cfg       : in layer_cfg_t;
    start     : in std_logic;
    busy, done, error : out std_logic;
    cycles    : out unsigned(31 downto 0);
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
    clk, rstn : in std_logic;
    cfg       : in layer_cfg_t;
    pix_valid : in std_logic;  pix_ready : out std_logic;
    pix_acc   : in std_logic_vector(LANES*ACC_W-1 downto 0);
    pix_oy, pix_ox, pix_kblk : in unsigned(...);
    -- FUSED only: skip_valid/skip_data from skip_reader
    -- write command and data ports of axi_master_wr
    pix_done  : out std_logic
  );
end entity;
```

### `requant` (1.2)

`y = (acc * m0 + 2^(shift-1)) >> shift`, round half up, arithmetic shift. Two outputs: the **wide** result (needed for the residual add, see below) and the result clipped to 0..127.

```vhdl
entity requant is
  generic ( PIPE : natural := 2 );
  port (
    clk, rstn : in std_logic;
    valid_in  : in std_logic;
    acc       : in acc_t;
    m0        : in unsigned(MULT_W-1 downto 0);
    shift     : in unsigned(5 downto 0);              -- 16 to 26 in the current export
    valid_out : out std_logic;
    y_wide    : out signed(ACC_W-1 downto 0);         -- unclipped
    y_relu8   : out act_t                             -- clipped to 0..127
  );
end entity;
```

Bit-exact to `requant()` in `quantize.py` (tested against the golden int32 and int8 vectors). One multiplier infers one DSP48E2 with the rounding constant on the C port.

### `skip_reader` (1.5, 4.6)

Reads the skip tensor from DDR in step with the output pixels: the block input for the identity shortcut of block 1, or the requantized shortcut-convolution result for blocks 2 and 3. Provides it to `writeback`.

```vhdl
entity skip_reader is
  port (
    clk, rstn : in std_logic;
    cfg       : in layer_cfg_t;
    req_valid : in std_logic;  req_ready : out std_logic;
    req_oy, req_ox, req_kblk : in unsigned(...);
    skip_valid : out std_logic; skip_ready : in std_logic;
    skip_data  : out std_logic_vector(LANES*ACT_W-1 downto 0)   -- or wider, see open point 6
    -- read command and response ports of axi_master_rd
  );
end entity;
```

The width of `skip_data` depends on open point 6: if the requantized shortcut must stay wider than int8, this becomes 16-bit or 32-bit lanes.

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
