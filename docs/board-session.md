# Board session: checklist and results sheet

For the 2026-11-11 deliverable (`docs/deliverable-11-11.md`, tasks P3, P4, M1 to M6). **Board: Avnet ZedBoard (Zynq-7000 XC7Z020, two ARM Cortex-A9 cores, 32-bit ARMv7)**, changed from the Ultra96 on 2026-11-04. Anything marked *from memory* is not verified; check it on the board and correct this file.

## 1. Before leaving

- [ ] Build the package on the laptop (Docker running), then copy `build/board.tar.gz` to the SD card or a USB stick as well:
  ```powershell
  docker run --rm -v "${PWD}:/work" -w /work/c radl-tf1 make package
  ```
  It holds `c/` (sources, `Makefile`, `board_run.sh`, static ARMv7 binaries in `c/armhf/`) and `build/export/`, about 2.3 MB.
- [ ] ZedBoard with its 12 V supply, micro-USB cable for the UART port, SD card with a Linux image (minimum; *from memory:* the ZedBoard takes a full-size SD card); Ethernet cable for SSH (optional). The boot jumpers are plastic caps already on the board, no cables needed; a spare 2.54 mm jumper cap in case JP6 has none. Which image the lab uses is unknown (D4): ask. *From memory:* PYNQ has no official ZedBoard image; PetaLinux, Analog Devices Kuiper or a Digilent image are common.
- [ ] USB card reader for full-size SD cards, to check and write the SD card and as the fallback copy path.
- [ ] Power meter answers (P5), see section 4.

## 2. First session (M1 to M3)

**Boot.** Power off, SD card in, then set the jumpers for SD boot (from Avnet's ZedBoard bring-up guide and a second guide, not yet checked against the Hardware User Guide's boot-mode table):

| Jumper | Signal | SD boot |
|---|---|---|
| JP7 | MODE0 | GND |
| JP8 | MODE1 | GND |
| JP9 | MODE2 | 3V3 |
| JP10 | MODE3 | 3V3 |
| JP11 | MODE4 | GND |
| JP6 | MIO0 | jumper installed (required on early boards with CES silicon) |

All of JP7 to JP11 on GND is JTAG boot, the recovery setting. Connect the UART cable first so the boot messages are visible, then switch the power on. If boot stops at a U-Boot prompt, type `boot`.

**Connect (M1).** Serial first, it works with any image:
- micro-USB to the port labeled UART (*from memory:* J14, Cypress USB-UART bridge; Windows may need its driver). Find the COM port in the Device Manager and open it with PuTTY at 115200 8N1.
- Login depends on the image, often `root`/`root` on PetaLinux.

Then Ethernet for copying, if the image runs an SSH server (`ps | grep -E 'sshd|dropbear'`). With a direct cable to the laptop, set static addresses: on the board `ip addr add 192.168.1.10/24 dev eth0; ip link set eth0 up`, on the laptop 192.168.1.1/24 for the Ethernet adapter. Then `ssh root@192.168.1.10`.

**Look around** and note the answers in the sheet (settles D4; the board revision is printed on the board):
```sh
uname -a; cat /etc/os-release; cat /proc/cpuinfo; gcc --version; make --version; nproc
ls /sys/devices/system/cpu/cpufreq/      # missing means no frequency scaling, the clock is fixed at boot
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor /sys/devices/system/cpu/cpu0/cpufreq/scaling_available_frequencies
df -h ~; free -m; ip addr
top -bn1 | head -20                      # background load (desktop, network services)
```

**Copy (M2).** With SSH, from the project root on the laptop: `scp build/board.tar.gz root@192.168.1.10:~`. Without a network: copy it to the SD card's FAT boot partition on the laptop, then on the board find it with `mount` (it may be mounted already) or `mount /dev/mmcblk0p1 /mnt`. On the board:
```sh
mkdir -p ~/camus && cd ~/camus && tar xzf ~/board.tar.gz && cd c      # or tar xzf /mnt/board.tar.gz
```

**Build (M2).** With gcc on the board: `make 2>&1 | tee make.log` gives native `camus_naive_O0` and `_O2`. Without gcc: use the prebuilt static binaries in `armhf/` (cross gcc 7.5, same flags as the Makefile, hard float, no NEON).

**First run (M3).** `board_run.sh` records the conditions (kernel, OS, CPU, gcc, governor, frequencies, load, md5 of the model files), then runs `-O0` and `-O2` pinned to the last core (core 1), and writes everything to `results_<host>_<date>.log`:
```sh
sh board_run.sh . 1        # native binaries, 1 pass
sh board_run.sh armhf 1    # prebuilt binaries
FRAMES=10 LEVELS=O2 sh board_run.sh armhf 1    # quick check: first 10 frames, -O2 only
```
Expect `accuracy 0.9550`, `bit-exact vs test_logits.bin: yes` and `exit code 0` for both. Rough guess, not measured: on a 667 MHz Cortex-A9 the `-O0` pass over 200 frames may take several minutes. If time allows, run native and prebuilt and note both.

**Copy back.** From the laptop: `scp "root@192.168.1.10:~/camus/c/*.log" docs/results/`, or copy the logs to the SD card and read it on the laptop. Then fill in section 3.

## 2a. Found on the lab board (session 2026-11-04)

- **Image:** the lab's SD card holds a camera-emulator demo (`ov7670_emulator_system_wrapper.bin`, `.ppm` test images, `BOOT.bin`, `uImage`, `devicetree.dtb`, `uramdisk.image.gz`). U-Boot 2015.07, Linux 4.0.0-xilinx-dev, BusyBox 1.23, root file system in RAM (lost on reboot).
- **Normal boot hangs** after `INIT: Entering runlevel: 5` (the demo runs and the console takes no input). **Workaround:** stop U-Boot at the prompt and boot into a plain shell:
  ```
  setenv bootargs console=ttyPS0,115200 rdinit=/bin/sh init=/bin/sh
  boot
  ```
  Then mount by hand: `mount -t proc proc /proc; mount -t sysfs sys /sys; mount -t devtmpfs devtmpfs /dev; mount /dev/mmcblk0p1 /mnt`. Before power off: `sync; umount /mnt`.
- **CPU:** 2 x Cortex-A9 (part 0xc09), NEON and VFPv3 present. No cpufreq, so the clock is fixed (no governor to set).
- **Tools:** no gcc, make or taskset (use the prebuilt `armhf/` binaries; runs are not pinned). Present: tar, gzip, md5sum, wget, nc, tftp.
- **Copy:** `eth0` has no address by default. Board `ifconfig eth0 192.168.1.10 netmask 255.255.255.0 up`, laptop Ethernet adapter `192.168.1.1/24`, laptop `python -m http.server 8000 --directory build`, board `cd /tmp; wget http://192.168.1.1:8000/board.tar.gz; tar xzf board.tar.gz`.
- **Logs back:** PuTTY session logging ("All session output" to a file).
- The SD card's FAT partition reports "not properly unmounted"; repair it on a PC (`chkdsk <drive>: /f`) when a card reader is available.
- **Ctrl+C does not work** in the bare shell (no controlling terminal). Try `exec setsid cttyhack sh` right after boot, or start long runs with `&` and stop them with `killall camus_naive_O0 camus_naive_O2`.
- **First quick check** (prebuilt `armhf/`, `-O2`, first 10 frames, not pinned, fixed clock): bit-exact, latency mean 1375 ms, min 1367, max 1381. Not a final number; the full runs over 200 frames are still to do.

## 3. Results sheet

Copy this block once per run. Lines marked (log) are in the `board_run.sh` log; only copy the summary here.

```
run id / date / who        :
board revision / OS image  : ZedBoard rev ... /
kernel / CPU / gcc         : (log)
connection, other load     : (serial / SSH over Ethernet; desktop or other services running?)
binary                     : native | prebuilt armhf/, flags
core / governor / freq     : (log; "no cpufreq" if the directory is missing)
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

## 4. Power meter (P5), questions to settle

- [ ] Who has the meter, and can it stay with us for the week?
- [ ] Does it log to a file or PC (sampling rate?), or must it be read by hand?
- [ ] Where it goes: between the 12 V supply and the board's barrel jack, so it measures the whole board. Check the voltage on the supply label.
- [ ] Alternative without an inline meter (confirmed by forum posts quoting the ZedBoard user guide): a 10 mOhm current-sense resistor in series with the 12 V input, with header J21 across it. Measure the voltage across J21 pins 1 and 2 with a multimeter (mV range): current = U / 0.01 Ohm, power = 12 V x current (example: 3.2 mV gives 320 mA, about 3.8 W). Only measure across J21, never draw current through it. A handheld meter with 0.1 mV resolution gives about 3 % on the total; the idle-to-loaded difference of one core is probably only 0.1 to 0.25 mV (guess), so `E_dynamic` needs 10 uV resolution or a logging meter.
- [ ] Resolution and accuracy in the expected range (a few watts)?

## 5. Later sessions (M4 to M6)

**Conditions (M4).** If cpufreq exists, fix the governor so the frequency does not move during a run (*from memory:* both A9 cores share one clock, so one policy sets both):
```sh
echo performance > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor
cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq
```
Without cpufreq the clock is fixed by the boot loader; note that in the sheet (*from memory:* 667 MHz on the ZedBoard's speed grade).

Scalar or not (open question 5): the A9 has NEON, but gcc only uses it with `-mfpu=neon`. `gcc -Q --help=target | grep mfpu` shows the board gcc's default and `gcc -Q --help=optimizers -O2 | grep tree-vectorize` whether it vectorizes at `-O2`. The prebuilt binaries use neither.

**Power (M5).** Same services and connection for both readings.
- Idle: board booted, nothing running, read the average over at least 60 s.
- Loaded: one binary at a time, with `reps` so the run lasts at least 60 s (reps = 60 / wall time of one pass, rounded up):
  ```sh
  taskset -c 1 ./camus_naive_O2 ../build/export <reps> | tee power_O2_<reps>.log
  ```
  Read the steady-state average, not the start-up.

**Energy (M6).** `t_frame = wall time / frames`, `E_total = P_loaded x t_frame`, `E_dynamic = (P_loaded - P_idle) x t_frame`. Repeat each measurement 3 times and report the spread. Only one of two cores is busy, so `E_dynamic` is the cost of one loaded core plus memory traffic.
