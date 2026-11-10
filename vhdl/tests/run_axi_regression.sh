#!/bin/bash
# Author: Olimjon Mirzayusupov
# regression of the AXI DDR master feature (docs/plans/axi-ddr-master.md) plus every existing testbench that uses
# camus_pkg, for one board; GHDL 7 with the LLVM/GCC backend (analysis, elaboration, run)
# usage, from vhdl/:  tests/run_axi_regression.sh <zedboard|ultra96> [workdir] [--quick] [--golden]
#   zedboard / ultra96  the board to test; if it is not the BOARD in src/camus_pkg.vhd, a copy of camus_pkg with the
#                       other BOARD is compiled from the workdir, src/camus_pkg.vhd itself is never changed
#   workdir             GHDL work directory and logs (default: /tmp/axi_regression_<board>), recreated on every run
#   --quick             one seed per configuration instead of three
#   --golden            also run the golden layer b3sc through the AXI integration testbench (slow, minutes)
# prints one line per run and exits with 1 if anything failed; the full output of a failing run is in <workdir>/logs
set -u
BOARD=${1:-}
case "$BOARD" in
    zedboard) BOARD_ID=ZEDBOARD ;;
    ultra96)  BOARD_ID=ULTRA96 ;;
    *) echo "usage: tests/run_axi_regression.sh <zedboard|ultra96> [workdir] [--quick] [--golden]"; exit 2 ;;
esac
shift
W=/tmp/axi_regression_$BOARD
SEEDS="1 2 3"
GOLDEN=0
for a in "$@"; do
    case "$a" in
        --quick)  SEEDS="1" ;;
        --golden) GOLDEN=1 ;;
        *)        W=$a ;;
    esac
done
[ -f src/camus_pkg.vhd ] || { echo "run from vhdl/"; exit 2; }
rm -rf "$W"; mkdir -p "$W/logs"
W=$(cd "$W" && pwd)

PKG=src/camus_pkg.vhd
if ! grep -q "constant BOARD : board_t := $BOARD_ID;" src/camus_pkg.vhd; then
    sed -E "s/constant BOARD : board_t := [A-Z0-9_]+;/constant BOARD : board_t := $BOARD_ID;/" src/camus_pkg.vhd > "$W/camus_pkg.vhd"
    PKG=$W/camus_pkg.vhd
fi
grep -q "constant BOARD : board_t := $BOARD_ID;" "$PKG" || { echo "could not select $BOARD_ID in camus_pkg"; exit 2; }
echo "board $BOARD_ID, camus_pkg from $PKG, workdir $W"

SRC="$PKG src/axi_pkg.vhd
     src/compute-engine/loop_nest.vhd src/compute-engine/addr_gen.vhd src/compute-engine/mac_int8.vhd
     src/compute-engine/requant.vhd src/compute-engine/conv_core_v1.vhd src/compute-engine/conv_engine_v1.vhd
     src/interface/axi_lite_regs.vhd src/interface/sync_fifo.vhd src/interface/axi_skid.vhd
     src/interface/axi_master_rd.vhd src/interface/axi_master_wr.vhd src/interface/axi_ddr_master.vhd
     src/conv_accel_top.vhd
     tests/models/axi_mem_model_pkg.vhd tests/models/axi_mem_model_shared.vhd tests/models/axi_mem_model.vhd
     tests/unit/tb_camus_pkg.vhd tests/unit/tb_axi_pkg.vhd
     tests/unit/compute-engine/tb_loop_nest.vhd tests/unit/compute-engine/tb_addr_gen.vhd
     tests/unit/compute-engine/tb_mac_int8.vhd tests/unit/compute-engine/tb_requant.vhd
     tests/unit/interface/tb_axi_lite_regs.vhd tests/unit/interface/tb_sync_fifo.vhd tests/unit/interface/tb_axi_skid.vhd
     tests/unit/interface/tb_axi_mem_model.vhd tests/unit/interface/tb_axi_master_rd.vhd tests/unit/interface/tb_axi_master_wr.vhd
     tests/integration/tb_conv_core_v1.vhd tests/integration/tb_conv_engine_v1.vhd tests/integration/tb_conv_engine_axi.vhd
     tests/integration/tb_conv_accel_top.vhd"
ghdl -a --std=08 --workdir="$W" $SRC > "$W/logs/analysis.log" 2>&1 || { echo "ANALYSIS FAILED, see $W/logs/analysis.log"; exit 1; }

TBS="tb_camus_pkg tb_axi_pkg tb_loop_nest tb_addr_gen tb_mac_int8 tb_requant tb_axi_lite_regs tb_sync_fifo tb_axi_skid
     tb_axi_mem_model tb_axi_master_rd tb_axi_master_wr tb_conv_core_v1 tb_conv_engine_v1 tb_conv_engine_axi tb_conv_accel_top"
for t in $TBS; do
    (cd "$W" && ghdl -e --std=08 --workdir="$W" "$t") > "$W/logs/elab_$t.log" 2>&1 || { echo "ELABORATION FAILED: $t"; exit 1; }
done

FAILS=0
N=0
run() {
    local t=$1; shift
    local log="$W/logs/${t}_$(echo "$*" | tr -c 'A-Za-z0-9=_' '_').log"
    N=$((N + 1))
    if timeout 3600 "$W/$t" "$@" > "$log" 2>&1 && grep -qE "\(report note\): PASS$" "$log"; then
        printf "PASS  %-20s %s\n" "$t" "$*"
    else
        printf "FAIL  %-20s %s   (log: %s)\n" "$t" "$*" "$log"
        FAILS=$((FAILS + 1))
    fi
}

# existing testbenches that use camus_pkg
for t in tb_camus_pkg tb_loop_nest tb_addr_gen tb_mac_int8 tb_requant tb_axi_lite_regs tb_conv_core_v1; do run $t; done
for l in tiny_a tiny_b tiny_c tiny_d tiny_e; do run tb_conv_engine_v1 -gG_LAYER=$l; done

# AXI-P1: helpers, FIFO, register slice
run tb_axi_pkg
for d in 1 2 3 64; do for s in $SEEDS; do run tb_sync_fifo -gG_DEPTH=$d -gG_SEED=$s; done; done
for s in $SEEDS; do run tb_axi_skid -gG_SEED=$s; done

# AXI-P2: the memory model (both widths)
for dw in 64 128; do for s in $SEEDS; do run tb_axi_mem_model -gG_DATA_W=$dw -gG_SEED=$s; done; done

# AXI-P3: read master, configurations r1..r5 of the plan
for s in $SEEDS; do
    run tb_axi_master_rd -gG_N_RD=1 -gG_DATA_W=64 -gG_READY_PCT=100 -gG_RD_LAT_MAX=30 -gG_REORDER=false -gG_SEED=$s
    run tb_axi_master_rd -gG_N_RD=4 -gG_DATA_W=64 -gG_READY_PCT=70 -gG_RD_LAT_MAX=12 -gG_REORDER=true -gG_SEED=$s
    run tb_axi_master_rd -gG_N_RD=4 -gG_DATA_W=64 -gG_READY_PCT=30 -gG_RD_LAT_MAX=40 -gG_REORDER=true -gG_SEED=$s
    run tb_axi_master_rd -gG_N_RD=4 -gG_DATA_W=64 -gG_READY_PCT=70 -gG_RD_LAT_MAX=12 -gG_REORDER=true -gG_RSP_READY_PCT=30 -gG_SEED=$s
    run tb_axi_master_rd -gG_N_RD=4 -gG_DATA_W=128 -gG_READY_PCT=70 -gG_RD_LAT_MAX=12 -gG_REORDER=true -gG_SEED=$s
done

# AXI-P4: write master, configurations w1..w5 of the plan
for c in 1 2 3 4 5; do for s in $SEEDS; do run tb_axi_master_wr -gG_CFG=$c -gG_SEED=$s; done; done

# AXI-P5: conv_engine_v1 through axi_ddr_master and the AXI model (data width from BOARD)
for l in tiny_a tiny_b tiny_c tiny_d tiny_e; do run tb_conv_engine_axi -gG_LAYER=$l; done
run tb_conv_engine_axi -gG_LAYER=tiny_e -gG_WR_LAT_MAX=20 -gG_FIFO=4
run tb_conv_engine_axi -gG_LAYER=tiny_b -gG_ERR=1
run tb_conv_engine_axi -gG_LAYER=tiny_b -gG_ERR=2
run tb_conv_engine_axi -gG_LAYER=tiny_a -gG_READY_PCT=100 -gG_RD_LAT_MAX=0 -gG_WR_LAT_MAX=0
if [ $GOLDEN -eq 1 ]; then run tb_conv_engine_axi -gG_LAYER=b3sc -gG_FRAME=f000; fi

# top level (task 2.3): the same layers driven through the AXI-Lite registers of conv_accel_top
for l in tiny_a tiny_b tiny_c tiny_d tiny_e; do run tb_conv_accel_top -gG_LAYER=$l; done
run tb_conv_accel_top -gG_LAYER=tiny_e -gG_WR_LAT_MAX=20 -gG_FIFO=4
run tb_conv_accel_top -gG_LAYER=tiny_b -gG_ERR=1
run tb_conv_accel_top -gG_LAYER=tiny_b -gG_ERR=2
run tb_conv_accel_top -gG_LAYER=tiny_a -gG_READY_PCT=100 -gG_RD_LAT_MAX=0 -gG_WR_LAT_MAX=0
if [ $GOLDEN -eq 1 ]; then run tb_conv_accel_top -gG_LAYER=b3sc -gG_FRAME=f000; fi

echo "board $BOARD_ID: $((N - FAILS)) of $N runs passed"
[ $FAILS -eq 0 ]
