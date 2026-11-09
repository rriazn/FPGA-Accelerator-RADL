# Performance and resource model (task 0.4)

Script: `tools/perf_model.py` (standard library only). Every assumption is a command line parameter, see `--help`. The numbers below are the **defaults**, which are placeholders until the block design and the board numbers are known.

```
python tools/perf_model.py                       # summary of all configurations
python tools/perf_model.py --per-layer v4        # per-layer table of one configuration
python tools/perf_model.py --sweep-latency       # v1 over several DDR read latencies
```

## Model

- **Compute cycles** per layer = OH x OW x ceil(K / lanes) x groups x tap cycles, with `groups = C` and `tap cycles = ceil(FY*FX / taps)`. With `pack1x1` a 1x1 layer uses the taps for 9 input channels instead (`groups = ceil(C / taps)`, one tap cycle). This is the formula of the spec (section 6.3), made general. Memory stalls are not part of it.
- **DDR cycles, buffered configurations (v2 and later):** every input pixel is read once (channels padded to 16, the single-channel frame stays plain), the int32 output is written in the blocked layout, weights and bias are loaded every frame (`--weights-resident` drops that). Bytes divided by `axi_bits/8 x axi_eff`. A layer takes max(compute, DDR), which assumes DDR traffic overlaps perfectly with compute.
- **DDR cycles, v1:** single-beat reads, `rd_latency + 1` clocks each divided by `outstanding`. Reads per layer: x (not in padding), w for every MAC, bias once per output.
- **Resources:** DSP = lanes x taps (+ `--extra-dsp`). BRAM36 = weights (the larger of capacity and read bandwidth) + line buffers (the larger of capacity and one BRAM per kernel row). Line buffers are a rough estimate.
- **Not modelled:** the ARM work between layers (requant, ReLU, residual add, pooling, FC, see D2), AXI-Lite and driver overhead, DDR refresh and arbitration, timing closure. `--arm-ms` adds a measured ARM time to the total.

## Defaults and where they come from

| Parameter | Default | Status |
|---|---|---|
| Clock | 200 MHz | confirmed (D5) |
| Deadline | 33 ms | project requirement |
| DSP48E2 / BRAM36 / UltraRAM | 360 / 216 / 0 | from secondary sources (see below), check against the AMD datasheet |
| BRAM36 data bits, widest port | 36,864 (with parity) / 72 | AMD architecture, check against the datasheet |
| AXI width, efficiency | 128 bit on the Ultra96 (64 bit on the ZedBoard: `--axi-bits 64`), 100 % of peak | **placeholder**, from the block design |
| v1 read latency, reads in flight | 30 clocks, 1 | **placeholder**, from the block design and the wrapper |
| Weights per frame | loaded every frame | conservative, open point 2 of the spec |

Sources for the device numbers (secondary, not the AMD document itself): the ZU3EG column of the [Zynq UltraScale+ MPSoC overview table](https://www.digikey.tw/zh/htmldatasheets/production/2085682/0/0/1/zynq-ultrascale-mpsoc-overview.html) (360 DSP slices, 216 block RAM, 0 UltraRAM, 70,560 LUTs), and [Circuit Cellar](https://circuitcellar.com/tech-news/product-news/ultra96-v2-sbc-adds-certified-wi-fi-and-industrial-temp-support/) for the 154K logic cells. The board has 2 GB LPDDR4, 32 bit ([boards.fpgadeveloper.com](https://boards.fpgadeveloper.com/boards/Ultra96v2)). The memory is on the PS side, so the PL reaches it through a PS AXI port whose width and clock come from the block design.

## Results with the defaults

| Config | Description | Cycles | ms | <= 33 ms | DSP | BRAM36 | MAC use | DDR MB |
|---|---|---|---|---|---|---|---|---|
| v1 | 1 MAC, no buffering (2.1) | 2,275,743,746 | 11,379 | NO | 1 | 0 | 100 % | 1,179 |
| v2 | 1 MAC, BRAM buffering (4.1) | 37,381,138 | 187 | NO | 1 | 20 | 100 % | 1.43 |
| v3 | 3x3 window, 9 MACs (4.2) | 4,867,090 | 24.3 | yes | 9 | 20 | 85 % | 1.43 |
| v4 | 16 lanes x 9 MACs (4.3) | 314,415 | 1.57 | yes | 144 | 20 | 85 % | 1.43 |
| v4-8 | 8 lanes x 9 MACs | 615,471 | 3.08 | yes | 72 | 20 | 85 % | 1.43 |
| v4-p | 16 x 9, 1x1 layers use 9 input channels | 278,535 | 1.39 | yes | 144 | 20 | 100 % | 1.43 |

Accelerator time for the nine conv layers only; the ARM part is not included.

## What the numbers say

1. **v1 is limited by DDR latency, not by the MAC.** With 30 clocks of latency and blocking single-beat reads it needs about 11 s per frame. The latency sweep gives 0.7 s at 1 clock and 37 s at 100 clocks. The earlier 187 ms figure assumed an ideal memory with separate read ports and does not apply to an AXI master (it is the row for v2, where compute is the limit). v1 still works as the functional baseline, but its latency measurement will be very large; allow the wrapper to keep several reads in flight (`--outstanding`) if a less extreme number is wanted.
2. **The 9-MAC window alone (v3) meets the deadline** on paper (24 ms at 200 MHz, no ARM time added), so 144 MACs is a margin and not a necessity. With ARM work added it may not be enough, which is why `--arm-ms` exists.
3. **16 x 9 gives 1.57 ms, close to the spec estimate** of 1.5 ms. The difference is the stem: it is **DDR-bound**, not compute-bound (13,343 against 3,136 cycles), because writing 16 int32 values per output pixel is 200 KB. This is the cost of D2 (int32 results to DDR). It does not matter for the deadline, but it is the argument for Fusion (4.6): int8 output is four times smaller.
4. **8 lanes (72 DSP) take 3.1 ms**, twice the cycles at half the DSPs. If timing or routing at 144 DSP is a problem, this is the fallback.
5. **The 1x1 shortcut layers use 11 % of the array.** Packing 9 input channels into the taps (`v4-p`) fixes that and saves about 36,000 cycles (11 %). It costs a different weight read path and window handling for 1x1 layers.
6. **Resources are modest.** 144 DSP is 40 % of the device. About 20 BRAM36 (9 %) hold the weights and line buffers, which leaves room for the partner's AXI blocks and for 4.8 (feature maps on-chip) if wanted.

## Open points

- Replace the placeholders for AXI width, efficiency and latency with the block design values (ask the system owner), and verify the device numbers with the AMD datasheet.
- Measure the ARM time per frame on the board and enter it with `--arm-ms`; until then the end-to-end latency is not known.
- Choose the PE array shape (this is the output of task 0.4). Proposal: build 16 x 9 (v4), keep `v4-p` and 8 lanes as options. The decision is open.
