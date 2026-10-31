#!/usr/bin/env python3
"""Performance and resource model for the conv accelerator (task 0.4).

Pure arithmetic, standard library only. Every assumption is a command line parameter,
the defaults are placeholders until the board and block design numbers are known.

  python tools/perf_model.py                       summary of all configurations
  python tools/perf_model.py --per-layer v4        per-layer table of one configuration
  python tools/perf_model.py --sweep-latency       v1 over several DDR read latencies
  python tools/perf_model.py --axi-bits 64 --rd-latency 60 --arm-ms 5
"""
import argparse
import math
import os
import sys
from collections import namedtuple

# name, K, C, H, W, FY, FX, stride, pad (H, W = input size, from the network topology)
LAYERS = [
    ("stem", 16, 1, 112, 112, 3, 3, 2, 1),
    ("b1c1", 16, 16, 56, 56, 3, 3, 1, 1),
    ("b1c2", 16, 16, 56, 56, 3, 3, 1, 1),
    ("b2c1", 32, 16, 56, 56, 3, 3, 2, 1),
    ("b2c2", 32, 32, 28, 28, 3, 3, 1, 1),
    ("b2sc", 32, 16, 56, 56, 1, 1, 2, 0),
    ("b3c1", 64, 32, 28, 28, 3, 3, 2, 1),
    ("b3c2", 64, 64, 14, 14, 3, 3, 1, 1),
    ("b3sc", 64, 32, 28, 28, 1, 1, 2, 0),
]
Layer = namedtuple("Layer", "name k c h w fy fx stride pad")
LAYERS = [Layer(*row) for row in LAYERS]

# lanes: output channels in parallel, taps: MACs per lane per cycle (kernel taps, 9 = one 3x3 window)
# buffered: weights in BRAM and line buffers (4.1 and later), otherwise every operand comes from DDR (v1)
# pack1x1: 1x1 layers use the taps for 9 input channels instead of 1 kernel tap
Config = namedtuple("Config", "name lanes taps buffered pack1x1 note")
CONFIGS = [
    Config("v1", 1, 1, False, False, "1 MAC, no buffering (2.1)"),
    Config("v2", 1, 1, True, False, "1 MAC, weights + line buffers in BRAM (4.1)"),
    Config("v3", 1, 9, True, False, "3x3 window, 9 MACs (4.2)"),
    Config("v4", 16, 9, True, False, "16 lanes x 9 MACs (4.3)"),
    Config("v4-8", 8, 9, True, False, "8 lanes x 9 MACs"),
    Config("v4-p", 16, 9, True, True, "16 x 9, 1x1 layers use 9 input channels"),
]
BLOCK = 16   # channel block of the memory layout


def ceil_div(a, b):
    return -(-a // b)


def out_dim(i, f, s, p):
    return (i + 2 * p - f) // s + 1


def valid_pairs(n_out, f, size, stride, pad):
    """number of (output position, kernel position) pairs that land inside the input"""
    return sum(1 for o in range(n_out) for k in range(f) if 0 <= o * stride - pad + k < size)


def layer_stats(l):
    oh = out_dim(l.h, l.fy, l.stride, l.pad)
    ow = out_dim(l.w, l.fx, l.stride, l.pad)
    macs = l.k * l.c * l.fy * l.fx * oh * ow
    valid = l.k * l.c * valid_pairs(oh, l.fy, l.h, l.stride, l.pad) * valid_pairs(ow, l.fx, l.w, l.stride, l.pad)
    return oh, ow, macs, valid


def check_layers(path):
    """compare the table above with layers.txt of the export, when it is there"""
    if not os.path.exists(path):
        return
    ref = {}
    for line in open(path):
        p = line.split()
        if p and not p[0].startswith("#") and len(p) >= 7 and p[0] in [l.name for l in LAYERS]:
            ref[p[0]] = tuple(int(v) for v in p[1:7])
    for l in LAYERS:
        if l.name in ref and ref[l.name] != (l.k, l.c, l.fy, l.fx, l.stride, l.pad):
            sys.exit("layer %s differs from %s: %s" % (l.name, path, ref[l.name]))


def compute_cycles(cfg, l, oh, ow):
    """cycles with every unit busy every cycle, no memory stalls"""
    kblk = ceil_div(l.k, cfg.lanes)
    if cfg.pack1x1 and l.fy * l.fx == 1:
        groups, tap_cycles = ceil_div(l.c, cfg.taps), 1
    else:
        groups, tap_cycles = l.c, ceil_div(l.fy * l.fx, cfg.taps)
    return oh * ow * kblk * groups * tap_cycles


def ddr_bytes(cfg, l, oh, ow, valid, macs, args):
    """useful bytes moved over the AXI port for one layer, and for v1 the number of single beat reads"""
    if not cfg.buffered:
        reads = valid + macs + l.k * oh * ow           # x (not in padding), w, bias per output
        writes = l.k * oh * ow
        return (reads + writes) * args.axi_bits // 8, reads
    cin = l.c if l.c == 1 else ceil_div(l.c, BLOCK) * BLOCK     # single channel input stays plain
    x = cin * l.h * l.w                                         # every input pixel read once
    out = ceil_div(l.k, BLOCK) * BLOCK * oh * ow * 4            # int32, blocked layout
    w = 0 if args.weights_resident else l.k * l.c * l.fy * l.fx + 4 * l.k
    return x + out + w, 0


def run(cfg, args):
    rows = []
    for l in LAYERS:
        oh, ow, macs, valid = layer_stats(l)
        comp = compute_cycles(cfg, l, oh, ow)
        byts, reads = ddr_bytes(cfg, l, oh, ow, valid, macs, args)
        if cfg.buffered:
            ddr = math.ceil(byts / (args.axi_bits / 8 * args.axi_eff))
        else:
            ddr = math.ceil(reads * max(1.0, (args.rd_latency + 1) / args.outstanding))
        cycles = max(comp, ddr) + args.layer_overhead
        util = macs / (comp * cfg.lanes * cfg.taps)
        rows.append(dict(name=l.name, macs=macs, comp=comp, ddr=ddr, cycles=cycles, util=util,
                         bytes=byts, bound="DDR" if ddr > comp else "compute"))
    return rows


def resources(cfg, args):
    dsp = cfg.lanes * cfg.taps + args.extra_dsp
    if not cfg.buffered:
        return dsp, 0, 0
    wbytes = sum(l.k * l.c * l.fy * l.fx + 4 * l.k for l in LAYERS)
    w_cap = ceil_div(wbytes * 8, args.bram_bits)
    w_bw = ceil_div(cfg.lanes * cfg.taps * 8, args.bram_port_bits)
    lb_bytes = max(l.c * l.w * l.fy for l in LAYERS)
    lb = max(ceil_div(lb_bytes * 8, args.bram_bits), max(l.fy for l in LAYERS))
    return dsp, max(w_cap, w_bw), lb


def md_table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "|".join("---" for _ in header) + "|"]
    out += ["| " + " | ".join(str(c) for c in r) + " |" for r in rows]
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    g = ap.add_argument_group("target and clock")
    g.add_argument("--clock-mhz", type=float, default=200.0, help="fabric clock (D5, confirmed)")
    g.add_argument("--deadline-ms", type=float, default=33.0, help="latency limit of the project")
    g.add_argument("--arm-ms", type=float, default=0.0, help="ARM work per frame outside the accelerator (requant, residual, pooling, FC until Fusion), measure on the board")
    g = ap.add_argument_group("DDR / AXI (placeholders, from the block design)")
    g.add_argument("--axi-bits", type=int, default=128, help="AXI data width")
    g.add_argument("--axi-eff", type=float, default=1.0, help="share of the AXI peak bandwidth that is reached (1.0 = theoretical peak)")
    g.add_argument("--rd-latency", type=int, default=30, help="clocks from read address to data, v1 only")
    g.add_argument("--outstanding", type=int, default=1, help="reads in flight at once, v1 only (1 = blocking single beat reads)")
    g.add_argument("--weights-resident", action="store_true", help="weights stay in BRAM between frames, otherwise they are loaded every frame")
    g = ap.add_argument_group("device (ZU3EG, to be verified with the datasheet)")
    g.add_argument("--dsp-total", type=int, default=360)
    g.add_argument("--bram36-total", type=int, default=216)
    g.add_argument("--bram-bits", type=int, default=36864, help="bits per BRAM36 that hold data (36864 with the parity bits, 32768 without)")
    g.add_argument("--bram-port-bits", type=int, default=72, help="widest BRAM36 port")
    g.add_argument("--extra-dsp", type=int, default=0, help="DSPs outside the array, for example 16 for requant (4.6)")
    g.add_argument("--layer-overhead", type=int, default=2, help="pipeline fill and drain clocks per layer (2 in the v1 simulation)")
    ap.add_argument("--per-layer", metavar="CONFIG", help="print the per-layer table of one configuration")
    ap.add_argument("--sweep-latency", action="store_true", help="print v1 for several read latencies")
    args = ap.parse_args()

    check_layers(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "build", "export", "layers.txt"))
    clk = args.clock_mhz * 1e3     # clocks per ms

    if args.per_layer:
        cfg = next((c for c in CONFIGS if c.name == args.per_layer), None)
        if cfg is None:
            sys.exit("unknown configuration, choose from " + ", ".join(c.name for c in CONFIGS))
        rows = run(cfg, args)
        print("%s: %s\n" % (cfg.name, cfg.note))
        print(md_table(["Layer", "MACs", "Compute cycles", "DDR cycles", "Cycles", "MAC use", "DDR bytes", "Bound by"],
                       [(r["name"], "{:,}".format(r["macs"]), "{:,}".format(r["comp"]), "{:,}".format(r["ddr"]),
                         "{:,}".format(r["cycles"]), "%.0f %%" % (100 * r["util"]), "{:,}".format(r["bytes"]), r["bound"])
                        for r in rows]))
        return

    if args.sweep_latency:
        cfg = CONFIGS[0]
        out = []
        for lat in (1, 10, 30, 60, 100):
            args.rd_latency = lat
            total = sum(r["cycles"] for r in run(cfg, args))
            out.append((lat, "{:,}".format(total), "%.0f" % (total / clk)))
        print("v1 with %d reads in flight\n" % args.outstanding)
        print(md_table(["Read latency (clocks)", "Cycles", "ms"], out))
        return

    summary = []
    for cfg in CONFIGS:
        rows = run(cfg, args)
        cycles = sum(r["cycles"] for r in rows)
        macs = sum(r["macs"] for r in rows)
        ms = cycles / clk + args.arm_ms
        dsp, wb, lb = resources(cfg, args)
        bram = wb + lb
        util = macs / (sum(r["comp"] for r in rows) * cfg.lanes * cfg.taps)
        ddr_mb = sum(r["bytes"] for r in rows) / 1e6
        bound = "DDR" if sum(r["ddr"] for r in rows) > sum(r["comp"] for r in rows) else "compute"
        summary.append((cfg.name, cfg.note, "{:,}".format(cycles), "%.2f" % ms, "yes" if ms <= args.deadline_ms else "NO",
                        "%d (%.0f %%)" % (dsp, 100.0 * dsp / args.dsp_total),
                        "%d (%.0f %%)" % (bram, 100.0 * bram / args.bram36_total),
                        "%.0f %%" % (100 * util), "%.2f" % ddr_mb, bound))
    print("clock %.0f MHz, AXI %d bit at %.0f %% of peak, read latency %d (v1), ARM %.1f ms, weights %s\n" % (
        args.clock_mhz, args.axi_bits, 100 * args.axi_eff, args.rd_latency, args.arm_ms,
        "resident" if args.weights_resident else "loaded every frame"))
    print(md_table(["Config", "Description", "Cycles", "ms", "<= %g ms" % args.deadline_ms, "DSP", "BRAM36", "MAC use",
                    "DDR MB", "Bound by"], summary))
    print("\nms is the accelerator time for the nine conv layers plus --arm-ms; the ARM part is not modelled.")


if __name__ == "__main__":
    main()
