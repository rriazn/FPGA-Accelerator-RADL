# CNN-CAMUS: cardiac view recognition, ResNet-8 (TF 1.x, int8)

RADL project. This repo holds the **Python part**: dataset pipeline, training, int8 quantization and export of weights and test vectors for the C reference and the FPGA accelerator.

## What the network does

It classifies a single grayscale echocardiography frame by **cardiac view**:

| Class | Meaning |
|---|---|
| 0 | 2-chamber view (2CH) |
| 1 | 4-chamber view (4CH) |

- **Input:** one 112x112 grayscale frame (ultrasound sector, orientation as stored in the CAMUS NIfTI files). Float model: pixel/255 in [0,1]. int8 model: `round(pixel/255*127)`, values 0..127 (scale 1/127, zero point 0).
- **Output:** 2 logits; the class is the argmax.
- **Data:** CAMUS, end-diastole (ED) and end-systole (ES) frames of both views: 500 patients x 2 views x 2 phases = 2,000 frames, 1,000 per class. Split **by patient** (fixed seed): 400 / 50 / 50 patients = 1,600 / 200 / 200 frames train / val / test.
- **Result (test, 200 frames):** 95.5 % float (BN folded) and 95.5 % int8; float and int8 predictions agree on every test frame. Target was >= 90 %. With only 200 test frames, one frame is 0.5 points.

### Architecture (ResNet-8, about 37.4 M MACs, 76 k weights)

All convs are followed by BN (folded into the conv before quantization). Padding is symmetric (3x3: pad 1, 1x1: pad 0). TF's `'same'` is not used, because it pads stride-2 convs on one side only.

| Layer | Op | Out (C x H x W) |
|---|---|---|
| `stem` | 3x3 conv, stride 2, ReLU | 16 x 56 x 56 |
| `b1c1`, `b1c2` | 3x3 conv, 16 -> 16; identity shortcut | 16 x 56 x 56 |
| `b2c1`, `b2c2`, `b2sc` | 3x3 conv stride 2 (16 -> 32), 3x3 conv 32 -> 32; 1x1 stride-2 shortcut conv | 32 x 28 x 28 |
| `b3c1`, `b3c2`, `b3sc` | same, 32 -> 64 | 64 x 14 x 14 |
| pool + `fc` | global average pool, dense 64 -> 2 | 2 |

Each block output is `ReLU(conv2 + shortcut)`.

### int8 scheme

Post-training, **symmetric, per-tensor** (weights and activations), zero point 0, so zero padding is exact. Activation ranges are the max |x| over 256 training frames.

```
acc (int32)  = sum(x_q * w_q) + b_q
y_q          = clip((acc * M0 + (1 << (SHIFT-1))) >> SHIFT, 0, 127)     # requant + ReLU, M0 is 16 bit
block output = clip(requant(conv2 acc) + requant(shortcut), 0, 127)     # both branches to the output scale
```

Block 1's identity shortcut has its own multiplier (`B1SKIP_*`). The global pool is exported as a **sum** over 14x14 = `POOL_N` = 196 positions; the 1/196 is folded into `fc_b`. Class = argmax of the int32 logits `fc_w . sum + fc_b`. `quantize.py` contains a numpy int8 forward that is bit-exact to this scheme; the C code and the accelerator must reproduce `test_logits.bin` exactly.

## Setup

TF 1.x needs Python <= 3.7, so everything runs in Docker (CPU, TF 1.15.5, Python 3.6).

```powershell
docker build -t radl-tf1 python
```

(Bash: use `$PWD` instead of `${PWD}` below.)

### Dataset

CAMUS is open but the official download needs registration and is slow. A Hugging Face mirror (`miyuki17/CAMUS_public`, a copy of the official NIfTI release; license CC BY-NC-SA 4.0, cite Leclerc et al., IEEE TMI 2019) works with the ED/ES files only, about 350 MB:

```powershell
pip install huggingface_hub
python -c "from huggingface_hub import snapshot_download as d; d('miyuki17/CAMUS_public', repo_type='dataset', allow_patterns=['database_nifti/*/*_[24]CH_E[DS].nii.gz'], local_dir='data/raw')"
```

Any other copy of the official layout (`patientNNNN/patientNNNN_{2CH,4CH}_{ED,ES}.nii.gz` anywhere below `data/raw`) works too.
Do not load the mirror with `datasets.load_dataset`; that only returns a `text` column of patient IDs.

## Usage

Run from the project root. Each step reads the previous step's output.

```powershell
# -> data/camus112.npz (stops unless it finds exactly 2,000 frames, 1,000 per view, 500 patients)
docker run --rm -v "${PWD}:/work" -w /work/python radl-tf1 python data.py --raw /work/data/raw
# -> build/float_params.npz (prints val acc per epoch, then test acc)
docker run --rm -v "${PWD}:/work" -w /work/python radl-tf1 python train.py
# -> build/quant.npz (prints float and int8 test accuracy)
docker run --rm -v "${PWD}:/work" -w /work/python radl-tf1 python quantize.py
# -> build/export/
docker run --rm -v "${PWD}:/work" -w /work/python radl-tf1 python export.py
```

`data.py --url <direct zip/tar link>` downloads and extracts an archive first.

| File | Role |
|---|---|
| `python/data.py` | NIfTI -> 112x112 uint8 frames, labels, patient-wise split |
| `python/train.py` | ResNet-8 in TF 1.x: 40 epochs, batch 32, Adam 1e-3 with cosine decay, +-6 px shift augmentation, best-validation checkpoint |
| `python/quantize.py` | BN folding, int8 quantization, numpy float and int8 reference forward, evaluation |
| `python/export.py` | C header, VHDL/BRAM files, test vectors |

## Exported files (`build/export/`)

Weights are int8 `[K][C][FY][FX]` row-major, biases int32 `[K]`, for each layer in `stem b1c1 b1c2 b2c1 b2c2 b2sc b3c1 b3c2 b3sc`.

| File | Content |
|---|---|
| `weights.h` | C arrays `<layer>_w`, `<layer>_b`, plus `#define`s for dims, stride, pad, `<LAYER>_M0`, `<LAYER>_SHIFT`, `B1SKIP_*`, `POOL_N`, `fc_w[2][64]`, `fc_b[2]` |
| `<layer>_w.mem`, `<layer>_b.mem` | same data as hex, one value per line (2 digits for weights, 8 for biases, two's complement), for BRAM init |
| `quant_pkg.vhd` | VHDL package with `M0` / `SHIFT` constants per layer |
| `layers.txt`, `fc_w.mem`, `fc_b.mem` | layer table (`name K C FY FX stride pad m0 shift`, plus `b1skip` and `fc` rows) and the FC weights; with the `.mem` files this is everything the C baseline loads |
| `test_x.bin` | int8 `[200][112][112]`, the test frames, already quantized |
| `test_y.bin` | uint8 `[200]`, labels (0 = 2CH, 1 = 4CH) |
| `test_logits.bin` | little-endian int32 `[200][2]`, expected output of the int8 network |
| `golden.npz` | int8 per-layer outputs (`gold_in`, `gold_stem`, `gold_b1h`, `gold_b1`, ...) of the first 4 test frames, for debugging a layer at a time |

## Naive C baseline (`c/`)

`c/camus_naive.c` is the RADL baseline: plain C11, libc only, one thread, straightforward loops with no tiling or SIMD. At run time it reads the layer table, weights and test set from `build/export/`, runs the int8 network on every test frame, and reports accuracy, latency (mean/min/max), frames over the 33 ms deadline, and whether every logit is **bit-exact** to `test_logits.bin` (exit code 1 if not). The ResNet-8 topology itself is fixed in the code.

```sh
cd c
make run              # builds and runs camus_naive_O0 and camus_naive_O2 on ../build/export
./camus_naive_O2 ../build/export 50   # 50 passes over the test set, e.g. for a long power measurement
```

Needs gcc and make; on the Ultra96 the same commands build a native aarch64 binary. Run `python/export.py` first (it writes `layers.txt`). On the Windows dev machine there is no C compiler, so it was built and run inside the `radl-tf1` Docker image:

```powershell
docker run --rm -v "${PWD}:/work" -w /work/c radl-tf1 make run
```

Host results (x86 under Docker, not the A53, so only useful as a correctness check): bit-exact on all 200 frames, 95.5 % accuracy, 278 ms/frame at `-O0` and 65 ms/frame at `-O2`. The numbers that count come from running it on the board.

## Open points

- The requant multiplier is 16 bit (`MULT_BITS` in `quantize.py`); confirm with the FPGA owner.
- VHDL weights are exported as `.mem` hex files, not VHDL arrays.
- Hyperparameters (epochs, learning rate, augmentation) and the activation range statistic (`PCT`, currently max) were chosen by us, not by the plan.
- `data/` and `build/` are generated and not meant to be committed.
