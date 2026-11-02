# ResNet-8 dataflow

Layer names match `CONVS` in `python/quantize.py`, `layers.txt` and the `.mem` file names. Tensor sizes are C x H x W (int8 activations). Conv and shortcut ops show kernel, stride and channels in -> out.

```mermaid
flowchart TD
    IN["in<br/>1 x 112 x 112"]

    IN --> STEM["stem: 3x3 conv, s2, p1<br/>1 -> 16, ReLU"]
    STEM --> S["stem<br/>16 x 56 x 56"]

    subgraph B1["Block 1 (identity shortcut)"]
        direction TB
        B1C1["b1c1: 3x3 conv, s1, p1<br/>16 -> 16, ReLU"]
        B1H["b1h<br/>16 x 56 x 56"]
        B1C2["b1c2: 3x3 conv, s1, p1<br/>16 -> 16"]
        B1SK["b1skip: requant only<br/>own multiplier"]
        B1ADD(("+ , ReLU"))
        B1C1 --> B1H --> B1C2 --> B1ADD
        B1SK --> B1ADD
    end

    S --> B1C1
    S --> B1SK
    B1ADD --> O1["b1<br/>16 x 56 x 56"]

    subgraph B2["Block 2 (1x1 conv shortcut)"]
        direction TB
        B2C1["b2c1: 3x3 conv, s2, p1<br/>16 -> 32, ReLU"]
        B2H["b2h<br/>32 x 28 x 28"]
        B2C2["b2c2: 3x3 conv, s1, p1<br/>32 -> 32"]
        B2SC["b2sc: 1x1 conv, s2, p0<br/>16 -> 32"]
        B2ADD(("+ , ReLU"))
        B2C1 --> B2H --> B2C2 --> B2ADD
        B2SC --> B2ADD
    end

    O1 --> B2C1
    O1 --> B2SC
    B2ADD --> O2["b2<br/>32 x 28 x 28"]

    subgraph B3["Block 3 (1x1 conv shortcut)"]
        direction TB
        B3C1["b3c1: 3x3 conv, s2, p1<br/>32 -> 64, ReLU"]
        B3H["b3h<br/>64 x 14 x 14"]
        B3C2["b3c2: 3x3 conv, s1, p1<br/>64 -> 64"]
        B3SC["b3sc: 1x1 conv, s2, p0<br/>32 -> 64"]
        B3ADD(("+ , ReLU"))
        B3C1 --> B3H --> B3C2 --> B3ADD
        B3SC --> B3ADD
    end

    O2 --> B3C1
    O2 --> B3SC
    B3ADD --> O3["b3<br/>64 x 14 x 14"]

    O3 --> POOL["global pool: sum over 14x14 = 196<br/>(1/196 folded into fc bias)"]
    POOL --> P["64"]
    P --> FC["fc: dense 64 -> 2<br/>int32 logits"]
    FC --> OUT["argmax: 2CH or 4CH"]
```

Both residual branches are requantized to the block output scale before the add. The shortcut is not clipped before the add, only the sum is clipped to 0..127.

## Per-layer sizes

| Layer | Kernel | Stride | Pad | In (C x H x W) | Out (C x H x W) | Weights | MACs |
|---|---|---|---|---|---|---|---|
| `stem` | 3x3 | 2 | 1 | 1 x 112 x 112 | 16 x 56 x 56 | 144 | 451,584 |
| `b1c1` | 3x3 | 1 | 1 | 16 x 56 x 56 | 16 x 56 x 56 | 2,304 | 7,225,344 |
| `b1c2` | 3x3 | 1 | 1 | 16 x 56 x 56 | 16 x 56 x 56 | 2,304 | 7,225,344 |
| `b2c1` | 3x3 | 2 | 1 | 16 x 56 x 56 | 32 x 28 x 28 | 4,608 | 3,612,672 |
| `b2c2` | 3x3 | 1 | 1 | 32 x 28 x 28 | 32 x 28 x 28 | 9,216 | 7,225,344 |
| `b2sc` | 1x1 | 2 | 0 | 16 x 56 x 56 | 32 x 28 x 28 | 512 | 401,408 |
| `b3c1` | 3x3 | 2 | 1 | 32 x 28 x 28 | 64 x 14 x 14 | 18,432 | 3,612,672 |
| `b3c2` | 3x3 | 1 | 1 | 64 x 14 x 14 | 64 x 14 x 14 | 36,864 | 7,225,344 |
| `b3sc` | 1x1 | 2 | 0 | 32 x 28 x 28 | 64 x 14 x 14 | 2,048 | 401,408 |
| `fc` | dense | - | - | 64 | 2 | 128 | 128 |
| **Total** | | | | | | **76,560** | **37,381,248** |

Biases (int32, one per output channel) are not counted in the weights column.
