# addr_gen rewrite: where the per-layer constants come from

Status 2026-11-20: **option A decided and implemented in simulation** (answers to the questions at the end). Not synthesized in Vivado and not run on the board yet. Follow-up to open point 1 of [v1-bringup-2026-11-18.md](../v1-bringup-2026-11-18.md#9-open) ("hardware precompute vs. OH/OW registers filled by the driver").

## Problem

`addr_gen` has no clock. In every clock it computes all four addresses again from the loop indices: `out_dim` divides by the stride, `elem_addr` divides and takes the remainder by the lane count, and up to three 32-bit multiplications are chained. The slowest path, from the config registers to `s_out_addr_d1` in `conv_core_v1`, is about 79 ns on the ZedBoard, so v1 runs at 10 MHz. `loop_nest` has a similar but shorter path: it computes `out_dim` in the clock of `i_start`.

## Shared by both options

The two options differ only in **who computes OH and OW** (the only real division). Everything else is the same:

- **Lane division.** `c mod L` and `k mod L` are small counters that move with c and k, so `/ L` and `mod L` disappear and any L from 1 to 16 works (implemented; the first version of this proposal suggested a shift, which would have limited L to 1 and 16).
- **Running pointers instead of products.** With the v1 loop order `k, oy, ox, c, fy, fx`, each step adds a per-layer constant to the pointer of the loop that advances. When a loop wraps, the inner pointers are reset to the pointer of the next outer loop.

| Address | Loop that advances | Add (bytes) |
|---|---|---|
| x | fx | `L_in` |
| x | fy | `W*L_in` |
| x | c | `1` inside a channel block, `H*W*L_in - (L_in-1)` when c enters the next block (L_in = 1: always `H*W`) |
| x | ox | `S*L_in` |
| x | oy | `S*W*L_in` |
| x | k | back to the start `in_base - (P*W + P)*L_in` (wraps mod 2^32, never read at padding positions) |
| w | every term | `1`, back to the k base at a new output element, k base `+ C*FY*FX` on k |
| b | k | `4` |
| out | ox (rows are contiguous) | `4*L_out`, back to the k base on k, k base `+ 4` inside a block, `+ 4*(OH*OW*L_out - (L_out-1))` when k enters the next block |

- **Padding check** from running `iy`, `ix`: the row start goes up by `S` on oy, and `iy = row start + fy`. The check is then a compare against 0 and H (W for `ix`), with no multiplication.
- **Per clock** this leaves one 32-bit add and a multiplexer per pointer, plus small compares. Expected to drop out of the critical path; not synthesized yet.
- **Latency.** The pointers are registers that move on the same `i_step` edge as `loop_nest`, so the addresses still belong to the term `loop_nest` shows. `conv_core_v1` keeps its `_d1`/`_d2` stages.
- **Constants computed once per layer:** `W*L_in`, `S*L_in`, `S*W*L_in`, `H*W*L_in`, `C*FY*FX`, `OH*OW*L_out` and the start offset. Each is one registered multiplication per setup clock (the factors L and S are at most 5 and 3 bits).

So both options need a short setup phase between `i_start` and the first term.

## Option A: hardware computes OH and OW too

A small sequential divider in the setup phase (repeated subtraction, about OH clocks; OH and OW run in parallel). For ResNet-8 that is at most about 60 clocks per layer. The smallest real layers (`b2sc`, `b3sc`, about 400 k MACs each) takes millions of clocks at 47 clocks per MAC, so this is negligible. Alternative: allow only strides 1, 2 and 4 and use a shift, which changes the supported range (spec open point).

- **+** Register map, `axi_lite_regs`, driver, stand-in, board programs, `tb_axi_lite_regs` and `tb_conv_accel_top` stay as they are.
- **+** No redundant state: the configuration cannot contradict itself.
- **+** Stays general for the random layers of task 0.5.
- **-** More RTL: a divider and a longer setup phase.
- **-** `tb_conv_core_v1` allows at most `MACs + 8` enabled clocks per layer; the bound has to grow by the setup length.

## Option B: the driver writes OH and OW

Two new registers in the reserved range (proposal: `0x44` OH, `0x48` OW). The hardware computes only the products.

- **+** No divider, setup of a few clocks.
- **+** The C side already has `accel_out_dim` (`c/accel_sim.c`).
- **-** Register map change across about ten files: `axi-interfaces.md` section 6, `axi_lite_regs`, `layer_cfg_t`, `accel_regs.h`, `accel.c`, `accel_sim.c`, and every testbench that builds a `layer_cfg_t` (`tb_loop_nest`, `tb_addr_gen`, `tb_conv_core_v1`, `tb_conv_engine_v1`, `tb_conv_engine_axi`, `tb_conv_accel_top`, `tb_axi_lite_regs`).
- **-** Redundant state. A wrong OH or OW gives wrong addresses without any error, and the engine can then write outside the output buffer in DDR (`/dev/mem`, no protection). Hardware can check it without dividing (`(OH-1)*S + FY <= H + 2P < OH*S + FY`, else error), but that adds back setup logic.
- **-** The setup phase is still needed for the products, so B saves only the divider.

Not proposed: the driver writes every constant (about nine registers). This removes setup in hardware, but moves the address arithmetic into C and makes the redundancy problem larger.

## Proposal

**Option A with the repeated-subtraction divider.** The RTL difference between A and B is one small divider. B pays for it with a register map change across about ten files and a new way to corrupt DDR, and the setup time does not matter in either option.

## Decisions (2026-11-20)

1. **Option A.**
2. **Sequential divider** (repeated subtraction), strides 1 to 7 stay allowed. Lanes are general (1 to 16) too: the channel lane is a counter, so no power-of-two restriction was needed.
3. **Pointers in `addr_gen`**, which gets `i_clk`, `i_rst`, `i_start`, `i_step` and `o_at_max` of `loop_nest` (index at its last value per loop; the lowest 0 bit is the loop that advances). The setup is a separate module, `layer_setup.vhd`; it also gives `loop_nest` its `OH` and `OW`, so `loop_nest` no longer divides either.
4. **Test:** `tb_addr_gen` drives the real `layer_setup` and `loop_nest` and compares every term with the old formulas (`elem_addr`, `out_dim` in `camus_pkg`), plus the new `tb_layer_setup`. Interfaces: [vhdl-modules.md](vhdl-modules.md#layer_setup-task-13).

Still to do: Vivado synthesis (new WNS, then the clock to set on the board), `accel_golden` and `camus_accel` bit-exact on the board.
