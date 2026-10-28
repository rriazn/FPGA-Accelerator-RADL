# Accelerator architecture diagrams

Rough block diagrams for `architecture-spec.md`. Mermaid; renders in VS Code (Markdown preview with a Mermaid extension), GitHub and most Markdown viewers. Block names are not final.

## 1. System

```mermaid
flowchart LR
    subgraph PS["Processing system (Zynq UltraScale+ PS)"]
        A53["ARM A53<br/>driver, requant + ReLU, residual add,<br/>global pool, FC, argmax"]
        DDRC["DDR controller"]
    end
    DDR[("DDR memory<br/>frame, feature maps, accumulators,<br/>weights + bias (read per MAC in v1,<br/>copied to BRAM from 4.1 on)")]
    subgraph PL["Programmable logic, 200 MHz"]
        REGS["AXI-Lite<br/>layer registers"]
        ACC["Conv accelerator"]
    end
    A53 -- "AXI-Lite: layer setup, start, status" --> REGS
    REGS --> ACC
    ACC -- "AXI master: read x, w, b / write acc" --> DDRC
    A53 --> DDRC
    DDRC <--> DDR
```

## 2. v1: naive accelerator (1 MAC, no buffering)

```mermaid
flowchart LR
    REGS["AXI-Lite registers"] --> FSM["Control FSM +<br/>address generator"]
    FSM --> RD["AXI master read<br/>(single beat)"]
    RD -- "x (int8)" --> MAC["1 MAC<br/>int8 x int8"]
    RD -- "w (int8)" --> MAC
    RD -- "bias (int32)" --> ACCR["int32 accumulator<br/>starts at bias"]
    MAC --> ACCR
    ACCR --> WR["AXI master write<br/>acc (int32)"]
    FSM -.-> ACCR
    FSM -.-> WR
```

## 3. Target architecture (after steps 4.1 to 4.4)

```mermaid
flowchart TB
    REGS["AXI-Lite registers<br/>+ cycle counter"] --> CTRL["Control FSM"]
    CTRL --> AG["Address and loop generator<br/>(layout with lanes L)"]
    AG --> RD["AXI master read"]
    AG --> WR["AXI master write"]

    RD -- "input rows" --> LB["Input line buffers<br/>BRAM, FY rows"]
    RD -- "weights, bias<br/>(once per layer)" --> WB["Weight + bias BRAM<br/>16 banks, one per lane"]
    LB --> WIN["3x3 window registers<br/>one input channel per cycle"]

    subgraph PE["PE array: 16 output lanes x 9 MACs = 144 DSP"]
        MACS["144 int8 MACs"] --> TREE["16 adder trees<br/>(9 products each)"]
        TREE --> ACCS["16 accumulators<br/>start at bias, over C channels"]
    end
    WIN --> MACS
    WB --> MACS

    ACCS --> WBK["Write-back path"]
    WBK -- "int32 x 16 = 64 B per pixel" --> WR

    SKIP["Skip tensor read<br/>(step 4.6 only)"] -.-> WBK
    RQ["Requant + ReLU + residual add<br/>(step 4.6 only)"] -.-> WBK
    RD -.-> SKIP
```

Dotted blocks are added by Fusion (4.6). Weights are loaded once per layer or network (open point 2 in the spec); everything else streams per output pixel.

## 4. One conv layer, v1

```mermaid
sequenceDiagram
    participant A as ARM A53
    participant R as AXI-Lite registers
    participant X as Accelerator
    participant D as DDR

    A->>R: write C, K, H, W, FY, FX, stride, pad, lanes, base addresses
    A->>D: input already in DDR (flush caches)
    A->>R: start
    loop for every output (k, oy, ox)
        X->>D: read x and w (per MAC), read bias
        X->>X: acc = bias + sum(x * w)
        X->>D: write acc (int32)
    end
    X->>R: done, cycle count
    A->>R: read status
    A->>D: read acc (invalidate caches)
    A->>A: requant and clip, add shortcut branch for block outputs
    A->>D: write int8 result for the next layer
```

## 5. Who does what per network stage (v1)

```mermaid
flowchart LR
    IN["Frame 112x112x1"] --> STEM["stem conv"]
    STEM --> B1["Block 1<br/>2 convs, identity skip"]
    B1 --> B2["Block 2<br/>2 convs + 1x1 skip conv"]
    B2 --> B3["Block 3<br/>2 convs + 1x1 skip conv"]
    B3 --> POOL["Global pool"]
    POOL --> FC["FC 64 to 2"]
    FC --> OUT["class = argmax"]

    classDef pl fill:#d9ecff,stroke:#2b6cb0,color:#000
    classDef ps fill:#fde8d7,stroke:#c05621,color:#000
    class STEM,B1,B2,B3 pl
    class POOL,FC,OUT,IN ps
```

Blue: convolutions run in the PL. Orange: ARM. The ARM also does requant, ReLU and the residual add between convs (until 4.6).
