# Board session: checklist and results sheet

For the 2026-11-11 deliverable (`docs/deliverable-11-11.md`, tasks P3, P4, M1 to M6). Anything marked *from memory* is not verified; check it on the board and correct this file.

## 1. Before leaving

- [ ] Build the package on the laptop (Docker running), then copy `build/board.tar.gz` to a USB stick as well:
  ```powershell
  docker run --rm -v "${PWD}:/work" -w /work/c radl-tf1 make package
  ```
  It holds `c/` (sources, `Makefile`, `board_run.sh`, static aarch64 binaries in `c/aarch64/`) and `build/export/`, about 2.3 MB.
- [ ] Ultra96 with its power supply, micro-USB cable, JTAG/UART pod for a serial console if there is one, microSD card with the OS image.
- [ ] Power meter answers (P5), see section 4.

## 2. First session (M1 to M3)

**Connect (M1).** The OS is unknown (D4). *From memory:*
- PYNQ image: micro-USB to the laptop gives a USB network, board at `192.168.3.1`. `ssh xilinx@192.168.3.1` (password `xilinx`), or Jupyter at `http://192.168.3.1:9090`, New, Terminal.
- PetaLinux or other: serial console over the JTAG/UART pod, 115200 8N1, login often `root`/`root`.

**Look around** and note the answers in the sheet (settles D4; the board revision v1 or v2 is printed on the board):
```sh
uname -a; cat /etc/os-release; gcc --version; make --version; nproc
ls /sys/devices/system/cpu/cpufreq/      # one policy per cluster
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies
df -h ~; free -m; ip addr
top -bn1 | head -20                      # background load (Jupyter, WiFi, desktop)
```

**Copy (M2).** From the project root on the laptop: `scp build/board.tar.gz xilinx@192.168.3.1:~`. Without a network: USB stick (`lsblk`, `sudo mount /dev/sda1 /mnt`) or the SD card's boot partition. On the board:
```sh
mkdir -p ~/camus && cd ~/camus && tar xzf ~/board.tar.gz && cd c
```

**Build (M2).** With gcc on the board: `make 2>&1 | tee make.log` gives native `camus_naive_O0` and `_O2`. Without gcc: use the prebuilt static binaries in `aarch64/` (cross gcc 7.5, same flags as the Makefile).

**First run (M3).** `board_run.sh` records the conditions (kernel, OS, gcc, governor, frequencies, load, md5 of the model files), then runs `-O0` and `-O2` pinned to one core, and writes everything to `results_<host>_<date>.log`:
```sh
sh board_run.sh . 1          # native binaries, 1 pass, core 3
sh board_run.sh aarch64 1    # prebuilt binaries
```
Expect `accuracy 0.9550`, `bit-exact vs test_logits.bin: yes` and `exit code 0` for both. If time allows, run native and prebuilt and note both.

**Copy back.** From the laptop: `scp "xilinx@192.168.3.1:~/camus/c/*.log" docs/results/`, then fill in section 3.

## 3. Results sheet

Copy this block once per run. Lines marked (log) are in the `board_run.sh` log; only copy the summary here.

```
run id / date / who        :
board revision / OS image  :
kernel / gcc               : (log)
connection, other load     : (USB net / serial / Jupyter; WiFi on? Jupyter running?)
binary                     : native | prebuilt aarch64/, flags
core / governor / freq     : (log)
command (exact)            :
log file                   :
frames / accuracy          :
bit-exact                  :
latency mean/min/max (ms)  :
frames over 33 ms          :
wall time (s), frames/s    :
P_idle / P_loaded (W)      : meter, how read (log file / by hand), averaging time
notes                      :
```

The summary table for the deliverable is in `docs/deliverable-11-11.md`, section 5.

## 4. Power meter (P5), questions to settle before Fri 10-30

- [ ] Who has the meter, and can it stay with us for the week?
- [ ] Does it log to a file or PC (sampling rate?), or must it be read by hand?
- [ ] Where it goes: between the board's DC supply and its barrel jack, so it measures the whole board. *From memory:* the Ultra96 takes 12 V; check the supply label.
- [ ] Resolution and accuracy in the expected range (a few watts)?

## 5. Later sessions (M4 to M6)

**Conditions (M4).** Fix the governor so the frequency does not move during a run (*from memory:* the four A53 cores share one cpufreq policy, so this sets all of them):
```sh
echo performance | sudo tee /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
cat /sys/devices/system/cpu/cpu3/cpufreq/scaling_cur_freq
```
Scalar or not (open question 5): `gcc -Q --help=optimizers -O2 | grep tree-vectorize` shows whether the board's gcc vectorizes at `-O2`. The prebuilt binaries (gcc 7.5) do not.

**Power (M5).** Same services and connection for both readings.
- Idle: board booted, nothing running, read the average over at least 60 s.
- Loaded: one binary at a time, with `reps` so the run lasts at least 60 s (reps = 60 / wall time of one pass, rounded up):
  ```sh
  taskset -c 3 ./camus_naive_O2 ../build/export <reps> | tee power_O2_<reps>.log
  ```
  Read the steady-state average, not the start-up.

**Energy (M6).** `t_frame = wall time / frames`, `E_total = P_loaded x t_frame`, `E_dynamic = (P_loaded - P_idle) x t_frame`. Repeat each measurement 3 times and report the spread. Only one of four cores is busy, so `E_dynamic` is the cost of one loaded core plus memory traffic.
