#!/bin/sh
# Record board conditions, then run camus_naive_O0 and _O2 pinned to one core; all output is also logged
#   sh board_run.sh [bin_dir] [reps] [core]     e.g. sh board_run.sh armhf 1 1
#   FRAMES=10 LEVELS=O2 sh board_run.sh armhf  quick check: first 10 frames, -O2 only
BIN=${1:-.}
REPS=${2:-1}
LEVELS=${LEVELS:-O0 O2}
[ -r /proc/cpuinfo ] || mount -t proc proc /proc  # missing in the bare shell after init=/bin/sh
[ -d /sys/devices ] || mount -t sysfs sys /sys
NCPU=$(grep -c ^processor /proc/cpuinfo)  # no nproc in BusyBox
CORE=${3:-$((NCPU - 1))}  # proposal: last core (1 on the ZedBoard), core 0 usually takes more interrupts
LOG=results_$(hostname)_$(date +%Y%m%d_%H%M%S).log
PIN="taskset -c $CORE"
command -v taskset >/dev/null || PIN=
{
  echo "== conditions"
  date
  uname -a
  grep -E '^(PRETTY_NAME|VERSION)=' /etc/os-release 2>/dev/null
  if command -v gcc >/dev/null; then gcc --version | head -n 1; else echo "no gcc"; fi
  grep 'model name' /proc/cpuinfo | head -n 1
  echo "cpus $NCPU"
  for f in scaling_governor scaling_cur_freq scaling_min_freq scaling_max_freq scaling_available_frequencies; do
    echo "cpu$CORE $f: $(cat /sys/devices/system/cpu/cpu$CORE/cpufreq/$f 2>/dev/null)"
  done
  uptime
  md5sum ../build/export/test_logits.bin ../build/export/layers.txt
  [ -z "$PIN" ] && echo "taskset missing: runs are NOT pinned"
  for O in $LEVELS; do
    echo "== $PIN $BIN/camus_naive_$O ../build/export $REPS $FRAMES"
    $PIN "$BIN/camus_naive_$O" ../build/export "$REPS" $FRAMES
    echo "exit code $?"
  done
} 2>&1 | tee "$LOG"
echo "log: $LOG"
