# Accelerator architecture specification

Status: working draft. Decisions D2, D3, D5 and D6 are settled (see `vhdl-accelerator-tasks.md`); items marked **proposal** or listed under "Open points" are not decided. Numbers marked *estimate* are my arithmetic from the layer shapes and need checking against the datasheet and the real design. The register map and layouts are finalized in task 0.3.

Companion diagrams: `architecture-diagram.md`.

## 1. Scope

An int8 convolution accelerator in the programmable logic (PL) of the Avnet Ultra96 (Zynq UltraScale+). The ARM A53 (processing system, PS) runs the network and offloads each conv layer. The accelerator runs **any** conv layer whose size is set at runtime (C, K, H, W, kernel, stride, padding); it is tuned for the ResNet-8 on CAMUS (about 37.4 M MACs per frame, 76,432 int8 weights).

| Settled | Value |
|---|---|
| Clock | 200 MHz (D5) |
| Hardware computes (v1) | convolution only: `acc = bias + sum(x*w)`, int32 out. Requant, ReLU, residual add on the ARM until Fusion, step 4.6 (D2) |
| Feature maps | in DDR, accessed by a custom AXI master in VHDL (D3) |
| Feature map layout | 16-channel-blocked with a lanes parameter L (D3), section 3 |
| Requant multiplier | 16 bit, used by the ARM from v1 and by hardware from 4.6 (D6) |
| Dataflow | output stationary, output parallel (plan) |

## 2. System

- **PS to PL control:** AXI-Lite slave in the accelerator holds the layer registers (section 4). The ARM writes them, sets start, then polls status (interrupt vs polling is open).
- **PL to DDR:** one AXI master port into a PS high-performance port, for reading inputs, weights and bias, and writing results. HP ports are not cache-coherent, so the driver must flush or invalidate caches around each layer, or use non-cached buffers. Port width and the coherent-port option depend on the block design (D4).
- **ARM work per frame (v1):** copy the frame to DDR; per conv layer program and start the accelerator; requant and ReLU; shortcut requant and residual add per block; global pool; FC; argmax.

## 3. Data formats and layout

- **Activations:** int8, zero point 0 (post-ReLU values 0..127). **Weights:** int8, `[K][C][FY][FX]`. **Bias:** int32, `[K]`. **Accumulator output:** int32.
- **Feature map layout (D3):** 16-channel-blocked with lanes parameter L:

  ```
  address(c, y, x) = (((c / L) * H + y) * W + x) * L + (c % L)        in elements
  L = 16 normally; L = 1 for the raw single-channel frame (plain [H][W] image)
  ```

  One pixel of one channel block is L contiguous elements: 16 bytes for int8 (one beat of a 128-bit AXI port), 64 bytes for int32 accumulators. Channel counts are padded to a multiple of 16 in memory. **Proposal:** lanes beyond K are written as zero.
- **Output dimensions** are derived by the hardware: `OH = (H + 2*PAD - FY) / STRIDE + 1`, same for OW. Padding is symmetric, zero.

## 4. Layer registers (AXI-Lite)

Proposal; offsets and widths are fixed in task 0.3.

| Register | Content |
|---|---|
| CTRL | start, soft reset |
| STATUS | busy, done, error |
| C, K | input and output channels |
| H, W | input height and width |
| FY, FX, STRIDE, PAD | kernel size, stride, padding |
| IN_LANES, OUT_LANES | L of input and output (1 or 16) |
| IN_BASE, W_BASE, B_BASE, OUT_BASE | DDR addresses of input, weights, bias, output |
| CYCLES | free-running or per-layer cycle counter, read by the ARM |
| *4.6 only:* M0, SHIFT, flags, SKIP_BASE, SKIP_M0, SKIP_SHIFT | fused requant, ReLU, residual add |

## 5. Compute semantics (v1)

For each output `(k, oy, ox)`:

```
acc[k][oy][ox] = bias[k] + sum over c, fy, fx of
                 x[c][oy*STRIDE - PAD + fy][ox*STRIDE - PAD + fx] * w[k][c][fy][fx]
                 (x = 0 outside the input)
```

All arithmetic is exact int32, bit-for-bit equal to the `acc` of `python/quantize.py` and `c/camus_naive.c`. The observed maximum |acc| on the test set is 89,677 (about 17.5 bits signed); the worst case for our largest layer is about 25 bits.

## 6. Micro-architecture

### 6.1 v1: naive (1 MAC, no buffering)

Register file, control FSM and address generator, AXI master (single-beat reads), one int8 x int8 MAC, one int32 accumulator, AXI master write of the int32 result. Weights and inputs are read from DDR for every MAC. Plan optimization 1.

### 6.2 Target (after steps 4.1 to 4.4)

Per output pixel, the array computes 16 output channels at once for **one input channel per cycle**:

- **Input path:** input line buffers in BRAM, with `FY` rows buffered, feed a 3x3 window register. Buffer size is C x W x FY bytes; for our network the largest is **2,688 B** (*estimate*), so it fits easily.
- **Weights:** all 76,432 weights (plus 1,344 B of bias) resident in BRAM. The array needs 16 x 9 = 144 weights per cycle (1,152 bit), so the weight memory is banked per output lane. Roughly 16 BRAM36 are needed for bandwidth and 17 to 19 for capacity, depending on whether the parity bits can be used (*estimate*; check BRAM port widths and capacity in the datasheet).
- **PE array:** 16 lanes x 9 MACs = 144 DSP48E2 (72 with int8 packing, step 4.5), each lane with an adder tree over its 9 products.
- **Accumulation:** 16 accumulators, initialized with the bias, accumulate over the input channels (output stationary). After C cycles one output pixel for 16 channels is complete.
- **Write-back:** 16 x int32 = 64 B burst through the AXI master. From step 4.6: requant (16 DSP, 16-bit multiplier), ReLU clip, and residual add in this path, with a second AXI read stream for the skip tensor.
- **1x1 convs** (`b2sc`, `b3sc`) use 1 of 9 taps, so 16 of 144 MACs are active during those layers.
- **Pipelining (4.4):** one new set of products per cycle; the adder tree and accumulator are pipelined to reach 200 MHz.

### 6.3 Per-layer cycle estimate for the target design (*estimate*, full array use, no stalls)

Cycles = OH x OW x ceil(K/16) x C.

| Layer | Cycles |
|---|---|
| stem | 3,136 |
| b1c1, b1c2 | 50,176 each |
| b2c1 / b2c2 / b2sc | 25,088 / 50,176 / 25,088 |
| b3c1 / b3c2 / b3sc | 25,088 / 50,176 / 25,088 |
| **Total** | **304,192, about 1.5 ms at 200 MHz** |

## 7. DDR buffers

- Weight and bias image, loaded or read as in section 8.
- Frame input, `[H][W]` int8 (L = 1): 12,544 B.
- Accumulator buffer, int32: at most 200,704 B (16 x 56 x 56 x 4).
- Activation buffers, int8: at most 50,176 B each; the ARM needs the block input, the intermediate tensor and the block output alive at the same time (and the shortcut accumulators).

## 8. Open points

1. **Owners (D1)** and **tools, Vivado version, board revision, ARM OS (D4).**
2. **Weight loading.** The plan says all weights are resident in BRAM and that any network runs. At runtime from DDR via the AXI master supports other networks but is limited by BRAM capacity; initializing BRAM at synthesis from the `.mem` files is simpler but fixes the network. v1 reads weights from DDR directly, so this only matters from step 4.1.
3. **Loop order.** Pixel-outer with the K blocks inside reads each input once, because all weights are on-chip. Output-channel passes outermost would re-read the input per pass. Decide in 4.1 to 4.3.
4. **Completion signalling:** polling or an interrupt.
5. **Lanes beyond K** written as zero (proposal) or left undefined.
6. **Shortcut branch width in step 4.6.** The requantized shortcut is added before clipping and may fall outside int8; it must be kept wider than int8, or clipped in the model after an accuracy check.
7. **Generality limit.** A 27-bit accumulator input to the requant DSP covers layers with C x FY x FX up to a few thousand; larger layers would need a wider path.
