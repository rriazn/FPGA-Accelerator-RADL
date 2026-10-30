#!/bin/sh
# Record board conditions, then run camus_naive_O0 and _O2 pinned to one core; all output is also logged
#   sh board_run.sh [bin_dir] [reps] [core]     e.g. sh board_run.sh aarch64 1 3
BIN=${1:-.}
REPS=${2:-1}
CORE=${3:-3}  # proposal: core 3, core 0 usually takes more interrupts
LOG=results_$(hostname)_$(date +%Y%m%d_%H%M%S).log
PIN="taskset -c $CORE"
command -v taskset >/dev/null || PIN=
{
  echo "== conditions"
  date
  uname -a
  grep -E '^(PRETTY_NAME|VERSION)=' /etc/os-release 2>/dev/null
  if command -v gcc >/dev/null; then gcc --version | head -1; else echo "no gcc"; fi
  echo "nproc $(nproc)"
  for f in scaling_governor scaling_cur_freq scaling_min_freq scaling_max_freq scaling_available_frequencies; do
    echo "cpu$CORE $f: $(cat /sys/devices/system/cpu/cpu$CORE/cpufreq/$f 2>/dev/null)"
  done
  uptime
  md5sum ../build/export/test_logits.bin ../build/export/layers.txt
  [ -z "$PIN" ] && echo "taskset missing: runs are NOT pinned"
  for O in O0 O2; do
    echo "== $PIN $BIN/camus_naive_$O ../build/export $REPS"
    $PIN "$BIN/camus_naive_$O" ../build/export "$REPS"
    echo "exit code $?"
  done
} 2>&1 | tee "$LOG"
echo "log: $LOG"
