# VHDL accelerator: task list

Goal (from "RADL plan: guideline essentials"): an int8 conv accelerator in the FPGA fabric of the Avnet Ultra96, written in VHDL. It is output-stationary and output-parallel (PE array of DSP MACs), with input line buffers and all ~77 k int8 weights in BRAM. Layer sizes (C, K, H, W, kernel, stride, padding) are set at runtime through AXI-Lite registers. The ARM A53 offloads conv layers and keeps global pooling and the 64x2 FC. It is compared on latency (33 ms deadline), energy per frame and accuracy against the naive C baseline (`c/`).

**How to read this.** IDs are `phase.task`. "Needs" lists tasks that must be finished first; tasks with no common dependency can run in parallel. Area tags follow the three owner rows of the plan, which are not yet assigned to people (open question in the plan):

- **[Core]** FPGA compute core: PE array, adder tree, accumulators, dataflow, int8 datapath, pipelining.
- **[Sys]** System integration: AXI-Lite, DMA, Vivado block design, ARM driver and tiling, residual and pooling handling, benchmark and power harness.
- **[Pipe]** Use case and dataset pipeline: Python training/quantization/export, naive C model, end-to-end evaluation.

Items marked *proposal* are my suggestion, not a decision of the plan.

## Overview

```
Phase 0  Spec + setup
   |
   +--> Phase 1  Shared building blocks (requant, address gen, registers)
   |         |
   |         v
   |    Phase 2  v1 naive accelerator (1 MAC, no buffering) ----+
   |                                                            |
   +--> Phase 3  Integration: block design, driver, harness ----+--> Phase 4  Optimization steps v2..v6
                                                                |         (each: implement, simulate,
                                                                |          synthesize, measure on board)
                                                                v
                                                          Phase 5  Final evaluation
                                                                v
                                                          Phase 6  Presentation + report
```

## Open decisions (settle in Phase 0)

| # | Question | Proposal |
|---|---|---|
| D1 | Who owns which part? | The plan leaves this open; confirm once the group is fixed. |
| D2 | What does v1 hardware compute? | **Decided:** only the convolution accumulation (`acc = bias + sum(x*w)`, int32 out). Requant, ReLU and the residual add stay on the ARM until step 4.6 (Fusion). Bias is also in hardware: the accumulator starts at the bias, so the output equals the `acc` of `quantize.py` exactly. Other hardware/ARM splits are benchmarked later if time allows (task 4.7). |
| D3 | Where do feature maps live between layers? | **Decided for v1:** feature maps in DDR, accessed through AXI, with weights and line buffers on-chip, and on-chip maps as the later optimization 4.8. **Layout decided: 16-channel-blocked `[C/16][H][W][16]`**, so 16 output channels are one contiguous write (address = (((c/16)*H + y)*W + x)*16 + c%16). Channel counts are padded to a multiple of 16 in memory; the layout gets a per-layer "lanes" parameter L (address = (((c/L)*H + y)*W + x)*L + c%L; L = 16 normally, L = 1 for the raw single-channel frame, which is then stored as the plain `[H][W]` image, as in `test_x.bin`). L goes into the AXI-Lite register map and the address generator (0.3, 1.3). Memory access: **custom AXI master in VHDL** (decided as the easier option for v1: irregular access pattern, simulates in GHDL, driver only writes base addresses; bursts are added with the line buffers in 4.1, and a DMA IP can be reconsidered then). The naive C baseline stays `[C][H][W]`; the ARM-side accelerator code and the hardware golden vectors (0.5) use the blocked layout. |
| D4 | Simulator and Vivado version, board revision (Ultra96 v1/v2), ARM OS (PYNQ, Petalinux, other)? | GHDL is already installed on the Windows dev machine; Vivado version and board setup are not known. |
| D5 | Target clock? | **Confirmed:** 200 MHz, the figure the plan uses for its 2.9 ms estimate. |
| D6 | Requant multiplier width? | **Decided: 16 bit** (`MULT_BITS`); [Core] can still object before the requant unit (1.2) is built. v1 hardware does not use it (D2), but the ARM-side requant and the golden vectors do. |

## Phase 0: Specification and setup

| ID | Area | Task | Needs | Output |
|---|---|---|---|---|
| 0.1 | all | Settle D1, D4, D5, D6. | none | decisions written into this file |
| 0.2 | Core, Sys | Set up tools: VHDL simulator, Vivado project skeleton for the Ultra96, board access, a way to run the C baseline on the A53. | 0.1 | working simulation + build flow |
| 0.3 | Core, Sys | Write the interface spec: AXI-Lite register map (C, K, H, W, FY, FX, stride, pad, base addresses, requant m0/shift, skip m0/shift, ReLU/residual flags, start, done, cycle counter), data layouts, handshake with the ARM, who tiles what. Settle D2 and D3 here. | 0.1 | `spec` document |
| 0.4 | Core | Performance and resource model for the PE configurations (1, 9, 144 MACs): cycle count per layer, BRAM and DSP use, DDR traffic. Rough first estimate for the 144-MAC array (16 output channels x 3x3 window, one input channel per cycle): about 304 k cycles per frame, 1.5 ms at 200 MHz, if the array is fully used. Check this estimate; 1x1 shortcut convs use only 16 of 144 MACs. Ultra96 ZU3EG has roughly 360 DSP and 216 BRAM36; verify against the datasheet. | 0.3 | model + chosen PE array shape |
| 0.5 | Pipe | Extend the golden vectors for hardware: per-layer input, int32 accumulator and requantized output for a few frames. **Format decided:** text files with one hex value per line, two's complement, like the exported `.mem` files. **Done for the network** (`build/export/golden/`, see README): frame 0 plus the frame with the largest \|acc\| (decided); for `c2` and shortcut layers the branch values before the add (`_rq`, option (a), decided), not the block output. `golden.npz` today only has int8 layer outputs for 4 frames. Also write random-layer vectors (arbitrary C, K, H, W, kernel, stride, pad) for the generality test. **Still to do, deferred (decided):** write them once 0.3 has fixed the supported ranges (kernel, stride, pad, maximum C/K/H/W) and open point 5 of the spec (lanes beyond K); not part of the first golden-vector export. | 0.3 | `export/` additions |

## Phase 1: Shared building blocks (VHDL)

Each block gets a testbench checked against the golden vectors. With D2, v1 needs only 1.1, 1.3 and 1.4; the requant unit (1.2) and the residual path (1.5) are first used in step 4.6.

| ID | Area | Task | Needs | Output |
|---|---|---|---|---|
| 1.1 | Core | int8 x int8 MAC / PE with int32 accumulator (signed, zero point 0). | 0.3, 0.5 | `mac_int8.vhd` + tb |
| 1.2 | Core | Requant unit: `(acc * m0 + (1 << (shift-1))) >> shift`, round half up, then ReLU clip to 0..127. Bit-exact to `quantize.py`. | 0.3, 0.5 | `requant.vhd` + tb |
| 1.3 | Core | Loop / address generator for runtime-sized layers (output pixel, input channel, window position, padding and stride handling, zero padding at borders). | 0.3 | `addrgen.vhd` + tb |
| 1.4 | Sys | AXI-Lite register file for the map from 0.3, plus start/done and a free-running cycle counter. | 0.3 | `regs.vhd` + tb |
| 1.5 | Core | Residual path in the write-back: skip tensor read, its own requant (identity skip of block 1 and the 1x1 shortcut convs), add, clip. Needed for 4.6. | 1.2 | `writeback.vhd` + tb |

## Phase 2: v1 naive accelerator (hardware baseline)

Plan optimization 1: one MAC unit, no buffering.

| ID | Area | Task | Needs | Output |
|---|---|---|---|---|
| 2.1 | Core | Conv engine FSM for one MAC unit: reads weight and input per MAC straight from DDR, accumulates in an int32 register, writes the accumulator out (D2). | 1.1, 1.3 | `conv_v1.vhd` |
| 2.2 | Core | Layer-level testbench: every conv layer of ResNet-8 vs golden accumulators, then the random layers from 0.5. | 2.1, 0.5 | passing simulation |
| 2.3 | Core, Sys | Top level with the AXI-Lite registers (1.4) and an AXI master to DDR; simulate end to end with a DDR model. | 2.2, 1.4 | `top_v1.vhd` |

## Phase 3: System integration (starts after 0.3, runs in parallel with Phases 1 and 2)

| ID | Area | Task | Needs | Output |
|---|---|---|---|---|
| 3.1 | Sys | ARM driver in C: write registers, start, wait for done, read the cycle counter. First against a software stand-in of the accelerator (the naive conv from `c/camus_naive.c`) so it can be developed before hardware exists. | 0.3 | `driver.c` |
| 3.2 | Sys | ARM side of the network: tiling if a layer exceeds on-chip limits, requant/ReLU/residual add (until 4.6), global pooling, FC, argmax. Check bit-exactness against `test_logits.bin`. | 3.1 | C inference using the accelerator |
| 3.3 | Sys | Vivado block design: Zynq PS, AXI-Lite and AXI master/DMA connections, clock, reset, address map. | 0.2, 0.3 | block design |
| 3.4 | Pipe | Run the naive C baseline on the A53 (`c/`, `-O0` and `-O2`) and record latency, accuracy and the deadline check. | 0.2 | baseline numbers |
| 3.5 | Sys | Benchmark and power harness: timers on the ARM, the accelerator cycle counter, a procedure for the DC power meter on the board supply (idle vs loaded, long runs via the `reps` argument of the C program). | 3.4 | measurement procedure |

## Phase 4: Optimization steps

Each step is a complete loop: implement, simulate against golden, synthesize (resources, timing at D5), run on the board with the harness (3.5), and add a row to the results table. Every step must stay bit-exact to `test_logits.bin`. The plan's order is 1 (done in Phase 2), then:

| ID | Area | Task | Needs | Output |
|---|---|---|---|---|
| 4.0 | Core, Sys | Bring v1 onto the board: synthesize, run on the block design, check bit-exactness, measure latency and energy. First hardware data point. | 2.3, 3.2, 3.3, 3.5 | v1 row in the results table |
| 4.1 | Core | BRAM buffering: all weights resident in BRAM (loaded once per layer via the BRAM init `.mem` or a load path), input line buffers, so fewer DDR accesses. | 4.0 | v2 |
| 4.2 | Core | Unroll the 3x3 window: 9 MACs plus adder tree. | 4.1 | v3 |
| 4.3 | Core | Unroll 16 output channels: 144 MACs, output-parallel PE array with one accumulator per output channel (output stationary). | 4.2 | v4 |
| 4.4 | Core | Pipelining: one new MAC set per cycle; timing closure at D5. | 4.3 | v5 |
| 4.5 | Core, Pipe | Data types: int8 DSP packing (two MACs per DSP48E2). Optionally lower bit widths; for that, [Pipe] adds a bit-width option to `quantize.py` and measures the accuracy effect (target at least 90 %). | 4.3 | v6a, accuracy-vs-bits table |
| 4.6 | Core, Sys | Fusion: requant, ReLU and residual add in the write-back path (1.5); the ARM no longer touches activations except pooling and FC. | 4.3, 1.5 | v6b |

| 4.7 | Core, Sys, Pipe | *Optional, if time allows.* Benchmark other hardware/ARM splits against the D2 choice, for example requant and ReLU in hardware without the residual add, or full fusion with the shortcut branch kept wider than int8. Same measurements and bit-exactness check as the other steps. | 4.6 | extra rows in the results table |
| 4.8 | Core, Sys | *Optional, if time allows.* Keep feature maps on-chip (BRAM) so consecutive layers chain without DDR round trips, including the block input kept for the skip path. Only possible after Fusion, since the ARM can no longer sit between layers. Largest map is 50 KB as int8; check it against the BRAM budget (0.4). Compare DDR traffic, latency and energy against the DDR version. Only suits this network's layer sizes, so larger layers still need the DDR path. | 4.6 | extra rows in the results table |

4.5 and 4.6 are independent of each other; both build on 4.3 (4.4 can run before or after). Combine the final configuration after all steps and re-measure.

## Phase 5: Final evaluation

| ID | Area | Task | Needs | Output |
|---|---|---|---|---|
| 5.1 | Pipe, Sys | Final run of the full network on the board: accuracy on the test set for the naive C and the accelerator (same int8 model and test set), bit-exactness check. | 4.4, 4.5, 4.6 | accuracy table |
| 5.2 | Sys | Final latency and energy per frame, at batch size 1, against the 33 ms deadline; report relative claims only ("X times less energy per frame than naive code on the same board, at the same accuracy"). | 5.1 | result table |
| 5.3 | Core, Pipe | Generality test: a few layers of other sizes through the AXI-Lite registers on the board (random layers from 0.5), checked against the C model. | 4.4 | pass/fail list |
| 5.4 | Core | Utilization, timing and power estimate report from Vivado for each version. | 4.0 to 4.6 | resource table |

## Phase 6: Presentation and report

| ID | Area | Task | Needs | Output |
|---|---|---|---|---|
| 6.1 | each | Own part: 10 min talk and 8 to 10 page report per person, using the example slides in "Slides/Project Presentation" as the model. | Phase 5 | slides, report |
| 6.2 | all | Group part (overlapping rows): up to 10 min and up to 10 pages. | Phase 5 | slides, report |

## Risks to watch

- **Timing at 200 MHz** with a 144-MAC array and adder tree; 4.4 may settle for a lower clock, which changes the latency estimate.
- **DSP packing (4.5)** is the most intricate datapath work; keep it optional until 4.3 and 4.4 are working.
- **Bit-exactness drift.** Any change to quantization on the Python side (for example a different `MULT_BITS` or bit width) changes the golden vectors; regenerate and re-run all testbenches.
- **Power measurement** needs a quiet baseline (idle board) and long runs; plan the setup early (3.5).
