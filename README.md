# CNN-CAMUS: int8 ResNet-8 and a VHDL conv accelerator

RADL project. An int8 ResNet-8 classifies one 112x112 CAMUS echocardiography frame as **2-chamber (0) or 4-chamber (1) view**. The repo holds the Python pipeline (TF 1.x training, int8 quantization, export), a naive C baseline, the ARM driver, and a VHDL convolution accelerator for the Zynq (ZedBoard now, Avnet Ultra96 as the final target).

## Status

| | Result |
|---|---|
| Accuracy (200 test frames) | 95.5 % float and 95.5 % int8, target >= 90 % |
| Naive C, ZedBoard Cortex-A9, `-O2` | about 1376 ms per frame, bit-exact (10-frame quick check, full run open) |
| v1 accelerator on the ZedBoard | whole network bit-exact, about 66.7 MHz, 33.8 s per frame (2026-11-25) |
| Deadline | 33 ms per frame |

v1 has one MAC and reads every operand straight from DDR, so it is slow by design. The next steps (bursts, line buffers, weights in BRAM) are in [docs/plans/vhdl-accelerator-tasks.md](docs/plans/vhdl-accelerator-tasks.md).

## The int8 contract

`python/quantize.py` defines a bit-exact int8 forward. The C baseline, the ARM driver and the accelerator must all reproduce `build/export/test_logits.bin` exactly.

```
acc   = sum(x_q * w_q) + b_q                                  # int32, what the v1 hardware returns
y_q   = clip((acc * M0 + (1 << (SHIFT-1))) >> SHIFT, 0, 127)  # requant + ReLU on the ARM, M0 16 bit
block = clip(requant(conv2) + requant(shortcut), 0, 127)
```

Symmetric per-tensor quantization, zero point 0, symmetric padding. Network table, int8 details and file formats: [docs/software.md](docs/software.md).

## Repository

| Path | Content |
|---|---|
| `python/` | `data.py` (CAMUS -> 112x112 frames), `train.py` (TF 1.x), `quantize.py` (BN folding, int8, reference forward), `export.py` (weights, `.mem`, test and golden vectors) |
| `c/` | `camus_naive.c` (baseline), `camus_accel.c` + `accel.c` (ARM side of the accelerator), `accel_sim.c` (host stand-in), `accel_probe.c`, `accel_golden.c` (board bring-up) |
| `vhdl/src/` | `compute-engine/` (MAC, loop nest, addr gen, conv core), `interface/` (AXI-Lite regs, AXI DDR master), top levels and block design wrappers |
| `vhdl/tests/` | GHDL unit and integration testbenches, AXI memory model, `run_axi_regression.sh` |
| `vhdl/constraints/` | XDC files |
| `tools/perf_model.py` | performance and resource model |
| `docs/` | plans, reports, board how-tos (below) |
| `presentation/` | slides |

`data/` and `build/` are generated and git-ignored.

## Quick start

Everything runs in Docker (TF 1.15.5 needs Python 3.6). Run from the project root, Docker Desktop running. In Bash use `$PWD` instead of `${PWD}`.

```powershell
docker build -t radl-tf1 python
docker run --rm -v "${PWD}:/work" -w /work/python radl-tf1 python data.py --raw /work/data/raw  # -> data/camus112.npz
docker run --rm -v "${PWD}:/work" -w /work/python radl-tf1 python train.py                       # -> build/float_params.npz
docker run --rm -v "${PWD}:/work" -w /work/python radl-tf1 python quantize.py                    # -> build/quant.npz
docker run --rm -v "${PWD}:/work" -w /work/python radl-tf1 python export.py                      # -> build/export/
docker run --rm -v "${PWD}:/work" -w /work/c radl-tf1 make run         # naive C, -O0 and -O2, checks bit-exactness
docker run --rm -v "${PWD}:/work" -w /work/c radl-tf1 make run-accel   # ARM side against the host stand-in
```

The CAMUS download (Hugging Face mirror, ED/ES files only, about 350 MB) is in [docs/software.md](docs/software.md#dataset). Board packages: `make package` (naive, ARMv7), `make package-accel` (accelerator, ARMv7), `make package64` (aarch64, Ultra96).

VHDL regression (GHDL, from `vhdl/`): `tests/run_axi_regression.sh zedboard`.

## Documentation

**Software and results**
- [docs/software.md](docs/software.md): network, int8 scheme, dataset, exported files, C programs and their options
- [docs/resnet8-diagram.md](docs/resnet8-diagram.md): ResNet-8 dataflow diagram
- [docs/deliverable-11-11.md](docs/deliverable-11-11.md): baseline deliverable, scope and measurement method

**Accelerator design** ([docs/plans/](docs/plans/))
- [vhdl-accelerator-tasks.md](docs/plans/vhdl-accelerator-tasks.md): task list and open decisions (start here)
- [architecture-spec.md](docs/plans/architecture-spec.md), [architecture-diagram.md](docs/plans/architecture-diagram.md): behavior, layouts, register map, block diagrams
- [vhdl-modules.md](docs/plans/vhdl-modules.md): module interfaces and VHDL conventions
- [axi-interfaces.md](docs/plans/axi-interfaces.md), [axi-ddr-master.md](docs/plans/axi-ddr-master.md): control and data links
- [addr-gen-rewrite.md](docs/plans/addr-gen-rewrite.md): per-layer constants, the fix that raised the clock from 10 to about 66.7 MHz
- [performance-model.md](docs/plans/performance-model.md): cycle and resource estimates
- [vivado-block-design.md](docs/plans/vivado-block-design.md): block design steps

**Board**
- [docs/connect-to-board.md](docs/connect-to-board.md): UART, Ethernet, jumpers
- [docs/board-session.md](docs/board-session.md): naive C baseline on the board, checklist and results
- [docs/run-accelerator-on-board.md](docs/run-accelerator-on-board.md): running the accelerator, start to finish
- [docs/v1-bringup-2026-11-18.md](docs/v1-bringup-2026-11-18.md): v1 bring-up report, problems and measurements

## Data

CAMUS (Leclerc et al., IEEE TMI 2019), CC BY-NC-SA 4.0. 500 patients x 2 views x ED/ES = 2,000 frames, split by patient 400/50/50.
