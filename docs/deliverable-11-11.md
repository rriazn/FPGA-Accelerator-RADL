# Deliverable 2026-11-11: baseline with measurements

Status: draft, written 2026-10-28. Everything marked **proposal** or **TBD** is not decided. Task IDs refer to `docs/plans/vhdl-accelerator-tasks.md`.

## 1. Deliverable

A baseline with measurements, due 2026-11-11. This plan reads it as the **software baseline: the naive plain-C int8 inference on one ARM A53 core of the Ultra96**, with latency, energy per frame and accuracy, and the measurement method written down (the plan's "benchmark against a naive implementation"). The hardware baseline (v1, 1 MAC, no buffering) is a stretch goal. **To confirm with the course requirements:** whether the deliverable means the software baseline, the v1 hardware, or both.

## 2. Scope

| Tier | Deliverable | Needs | Acceptance |
|---|---|---|---|
| **Must** | Naive C on the board: latency, the 33 ms check, accuracy, energy per frame, method written down | board access and OS (D4), DC power meter | table in section 5 filled for `-O0` and `-O2`; accuracy 95.5 % and `bit-exact: yes` on the board; method reproducible from the text |
| **Likely** | v1 hardware modules simulated in GHDL against golden vectors, with cycle counts per layer from simulation | 0.3 (spec frozen), 0.5 (golden vectors), D4 simulator | testbenches pass for `mac_int8`, `loop_nest`, `addr_gen` and `conv_engine_v1` on at least the stem and `b1c1`; cycles per layer listed and clearly labeled "simulated, not measured" |
| **Stretch** | v1 on the board for one layer, then the full network | Vivado block design, ARM driver, cache handling | one layer's int32 accumulators on the board equal the golden vectors; cycle counter read back |

Not in scope for these two weeks: any optimization step (4.1 onward), fusion, DSP packing, lower bit widths.

## 3. Timeline (proposal)

| Date | Milestone |
|---|---|
| Wed 2026-10-28 and Thu 10-29 | **No board yet.** Do the preparation tasks P1 to P5 (section 4), so the first board session is not spent on setup. Confirm power meter availability and who operates it. Start the Likely tier (L1, L2). |
| Fri 2026-10-30 | **Board access starts.** First session: M1 to M3 (shell, copy, build or use the prepared binaries, first run). Settle D4 from what is found. |
| Mon 11-02 | Naive C builds and runs on the board; accuracy 95.5 % and bit-exact. First latency numbers. |
| Wed 11-04 | First power readings (idle and loaded). Measurement method fixed after the first dry run. |
| Fri 11-06 | Final measurement runs for `-O0` and `-O2`; table filled. In parallel (Likely tier): 0.3 frozen, golden vectors exported, first modules simulating. |
| Mon 11-09 | Numbers and method frozen; write-up and slides drafted. |
| Tue 11-10 | Buffer: reruns, fixes, review. |
| Wed 11-11 | Deliverable. |

Board access starts Fri 10-30, so only the first session and the following weekend and week are available. If the board turns out not to be usable on Fri 10-30, or the meter is not available by Mon 11-02, move the Must-tier work to simulation-side preparation and say so in the write-up; do not fill the table with host numbers. Whether the board stays available after Fri 10-30 (the whole time, or only in the lab) is not known: **TBD**.

## 4. Tasks

### Before board access (Wed 10-28 and Thu 10-29)

Board access starts Fri 10-30, and nothing here needs the board.

| # | Task | Output | Status |
|---|---|---|---|
| P1 | Cross-compile `camus_naive` for aarch64 as static binaries (`-O0` and `-O2`) in Docker, as a fallback if the board has no gcc or no internet. | `camus_naive_O0` and `_O2` for aarch64 | done: `make cross` in the `radl-tf1` image (cross gcc 7.5), binaries in `c/aarch64/`; bit-exact under arm64 emulation |
| P2 | Prepare one transfer package: `c/` sources, the prepared binaries, `build/export/` (3.9 MB), on a USB stick or ready to `scp`. | package ready | done: `make package` writes `build/board.tar.gz` (2.3 MB); copying to a USB stick is left |
| P3 | Write the first-session checklist: connect (serial/SSH/Jupyter), `uname -a`, `gcc --version`, `nproc`, CPU frequency and governor, build, run, copy results back. | checklist | done: `docs/board-session.md` section 2; `c/board_run.sh` records the conditions and runs both binaries |
| P4 | Draft the measurement notes (section 5) and a results sheet to fill in during the session, including a place for the exact commands run. | sheet ready | done: `docs/board-session.md` sections 3 and 5 |
| P5 | Find out who has the power meter, whether it logs readings or must be read by hand, and where in the supply line it goes. | meter status | open, needs a person: questions in `docs/board-session.md` section 4 |

### Must tier: software baseline on the board

| # | Task | Needs | Output |
|---|---|---|---|
| M1 | Get a shell on the board (serial, SSH or Jupyter terminal); note the OS image and kernel | D4 | working connection, OS noted |
| M2 | Copy `c/` and `build/export/` to the board; build with `make` (or cross-compile statically for aarch64 in Docker if the board has no gcc) | M1 | `camus_naive_O0`, `camus_naive_O2` on the board |
| M3 | First run: check accuracy 95.5 % and `bit-exact: yes`; record mean/min/max latency | M2 | first numbers |
| M4 | Set up the measurement conditions: pin to one A53 core, fix the CPU frequency governor, note gcc version and flags, decide on `-fno-tree-vectorize` (see below) | M3 | recorded conditions |
| M5 | Power measurement: DC meter in the board supply line, idle reading, loaded reading during a long run (`reps` argument) | M4, meter | power readings |
| M6 | Compute energy per frame and fill the table; repeat runs to check spread | M5 | results table |
| M7 | Write the method section: setup, commands, formulas, what was recorded | M6 | text for the report and slides |

### Likely tier: v1 hardware in simulation

| # | Task | Task list ID | Needs |
|---|---|---|---|
| L1 | Freeze the register map, port widths, module names | 0.3 | decisions in `vhdl-modules.md` |
| L2 | Per-layer golden vectors in the chosen layout (input, int32 accumulator, requantized output); random-layer vectors are deferred until 0.3 settles the ranges, still open in task 0.5. **Network vectors done** (`build/export/golden/`) | 0.5 | L1 (Pipe side) |
| L3 | `mac_int8`, `loop_nest`, `addr_gen` plus testbenches | 1.1, 1.3 | L1, L2 |
| L4 | `axi_master_rd` / `axi_master_wr` and a simulation memory model | 2.3 | L1 |
| L5 | `conv_engine_v1` and a layer-level testbench on the stem and `b1c1`, then all layers | 2.1, 2.2 | L3, L4 |
| L6 | Extract cycle counts per layer from simulation | | L5 |

### Stretch tier

`axi_lite_regs`, the top level, the Vivado block design, the ARM driver (with cache handling) and bring-up on the board: tasks 1.4, 2.3, 3.1, 3.3 and 4.0. Start only if L5 passes before Mon 11-06.

## 5. Measurement method and results table (proposal)

**Per run, record:** board and OS image, kernel version, gcc version and flags, core used, CPU frequency and governor, date, ambient conditions if relevant, the program's printed output (frames, accuracy, bit-exactness, latency mean/min/max, frames over 33 ms, wall time).

**Latency:** printed by the program, for `infer()` only (file loading excluded), batch size 1. Mean/min/max over 200 frames; the check "frames over 33 ms" gives the deadline result.

**Energy per frame** (report both):
- `E_total = P_loaded × t_frame`
- `E_dynamic = (P_loaded - P_idle) × t_frame`

with `t_frame = wall time / frames` for a sequential run. Use `./camus_naive_O2 ../build/export <reps>` with `reps` chosen so the run lasts long enough for the meter to settle (proposal: at least about 60 s), read the steady-state average, and take the idle reading with the same services running and no inference.

**Compiler flags:** gcc 12 and later auto-vectorize at `-O2` (from memory), so an A53 may use NEON even in this code. Decide whether the baseline must be strictly scalar; if yes, add `-fno-tree-vectorize` and say so in the write-up.

| | `-O0` | `-O2` |
|---|---|---|
| Test accuracy (int8) | | |
| Bit-exact vs `test_logits.bin` | | |
| Latency mean / min / max (ms) | | |
| Frames over 33 ms | | |
| P_idle / P_loaded (W) | | |
| E_total / E_dynamic per frame (mJ) | | |

## 6. Risks

| Risk | Mitigation |
|---|---|
| No board or meter access in time | Ask now; if missing by 11-02, report the limitation and the plan, not host numbers. |
| Board has no gcc or no network | Cross-compile statically in Docker; copy via SD card or serial if needed. |
| Unstable power readings (WiFi, background services) | Long runs, an idle reading under the same conditions, repeat runs and report the spread. |
| Naive C already fast enough, or far slower, than the plan's estimate | Report what is measured; the plan's 31 ms figure is only an estimate. |
| Likely/Stretch tiers eat into the Must tier | Must tier has priority; stop work on L-tasks when a Must task is blocked on a person. |

## 7. Open questions

1. Does the deadline mean the software baseline, the v1 hardware, or both?
2. Which OS image is on the Ultra96, and is a shell reachable (D4)?
3. Is a DC power meter available, and who operates it?
4. Who does which task? The presentation lists system integration and benchmarking for two names, but the plan has three areas and the slide still has a TODO (D1).
5. Strict scalar baseline or compiler default (see section 5)?
