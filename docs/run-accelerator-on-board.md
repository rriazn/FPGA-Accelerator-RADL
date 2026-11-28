# Run the v1 accelerator on the ZedBoard: commands, start to finish

Written for the team. This is the sequence that worked on 2026-11-18 (at 10 MHz). Updated 2026-11-25 for the bitstream with the new address generation: the whole network ran bit-exact with a clock request of 70 MHz (about 66.7 MHz real, 33.8 s per frame); 75 MHz failed in `b2c2`, see section 6. The board is reached as in [connect-to-board.md](connect-to-board.md) (UART on the micro USB, Ethernet cable, PC on Windows). Why each step is needed, and what went wrong on the way, is in [v1-bringup-2026-11-18.md](v1-bringup-2026-11-18.md) and [plans/vivado-block-design.md](plans/vivado-block-design.md).

Replace `design_1_wrapper.bin` with the name of your bitstream. Stop at the first check that fails.

## 1. PC (Windows, PowerShell as Administrator)

Once per session:
```powershell
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 192.168.1.1 -PrefixLength 24
New-NetFirewallRule -DisplayName "board http" -Direction Inbound -Protocol TCP -LocalPort 8000 -RemoteAddress 192.168.1.10 -Action Allow
New-NetFirewallRule -DisplayName "board ping" -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -RemoteAddress 192.168.1.10 -Action Allow
```
- Skip any line that says the address or rule already exists.
- The firewall rules are needed because the board's `ping` and `wget` are blocked by default on the direct cable (Windows treats it as a public network). They only accept the board's address and are removed at the end.

Open PuTTY on the serial port (115200 baud). Then start the file server and leave it running:
```powershell
cd C:\Users\Roman\Projects\Uni\RADL\CNN-CAMUS
python -m http.server 8000 --bind 192.168.1.1 --directory build
```
Check that these exist: `build\board-accel.tar.gz` (made with `make package-accel` in `c/`) and `build\bitstream\design_1_wrapper.bin`.

## 2. Board: U-Boot

Press *Reset* and hit Enter right away, until the prompt reads `zynq-uboot>` (the countdown is only 3 seconds):
```
setenv initrd_high 0xffffffff
setenv fdt_high 0xffffffff
setenv bootargs console=ttyPS0,115200 rdinit=/bin/sh init=/bin/sh mem=496M
boot
```
- `mem=496M` keeps the top 16 MB of the 512 MB DDR away from Linux, for the accelerator's DMA buffers.
- The first two lines stop U-Boot from moving the ramdisk and the device tree to the top of RAM. Without them the boot ends in `Kernel panic ... Unable to mount root fs`.
- Do not use `saveenv`. The lines have to be typed after every Reset.

## 3. Board: shell (`sh-4.3#`)

```
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs devtmpfs /dev
ifconfig eth0 192.168.1.10 netmask 255.255.255.0 up
```
Wait about 20 seconds (the Ethernet link restarts), then check:
```
cat /proc/cmdline
grep MemTotal /proc/meminfo
ping -c 3 192.168.1.1
```
- `cmdline` must contain `mem=496M`.
- `MemTotal` must be **below 507904 kB** (it showed 513200 kB when `mem=` was missing). If it is not, the reserved range is not safe. Root file system and `/tmp` are in RAM, so memory the kernel still owns can hold your files, and the accelerator writing there would corrupt them.
- If the ping fails: check the cable, the address on the PC (`Get-NetIPAddress -InterfaceAlias "Ethernet" -AddressFamily IPv4`) and the firewall rules above. A test from the PC side, `ping 192.168.1.10`, is not affected by the firewall.

## 4. Copy the files

```
cd /tmp
wget http://192.168.1.1:8000/board-accel.tar.gz
wget http://192.168.1.1:8000/bitstream/design_1_wrapper.bin
tar xzf board-accel.tar.gz
```
`/tmp` is RAM, so this is repeated after every Reset. `c/armhf/` now has `accel_probe`, `accel_golden` and `camus_accel`, and `build/export` has the weights and the golden frame f000.

## 5. Load the bitstream

```
D=/sys/devices/soc0/amba/f8007000.devcfg
cat $D/is_partial_bitstream
cat design_1_wrapper.bin > /dev/xdevcfg
cat $D/prog_done
```
- `is_partial_bitstream` must be `0` (a full bitstream), and `prog_done` must print **`1`**.
- If not, run `dmesg | tail -20`. A `.bin` in the wrong format is the usual cause; convert the `.bit` with bootgen on the PC (a `full.bif` with `all:{ design_1_wrapper.bit }`, then `bootgen -image full.bif -arch zynq -process_bitstream bin`) and use that file *(check)*.

## 6. Set the PL clock (after loading, before running anything)

The clock comes from the boot image on the SD card, not from the bitstream, and the lab image starts it at about 100 MHz (99,999,999 Hz). The accelerator must not run faster than the clock it was built for.
```
echo fclk0 > $D/fclk_export
cat /sys/class/fclk/fclk0/set_rate
echo 70000000 > /sys/class/fclk/fclk0/set_rate
cat /sys/class/fclk/fclk0/set_rate
```
- The first `cat` shows what the boot image gave you. The last one shows what the kernel really set after rounding to the PLL's integer dividers (about 76.9 MHz is possible).
- **The last value must be no higher than the Actual frequency that Vivado shows for the loaded bitstream** (Vivado checks the timing against that value). If it is higher, do not run.
- If `fclk0` is missing, `fclk_export` was not run (the directory `/sys/class/fclk` is empty after every boot). If you export before loading the bitstream, export again after loading.
- A register read before the bitstream is loaded and the clock is set **hangs the board**. `Ctrl+C` does not work in this shell, only *Reset* helps, and then everything from section 2 is repeated.
- For the first 10 MHz bitstream use `10000000` instead.
- **Measured on the board (2026-11-25), bitstream with the new address generation, built while Vivado still used a 100 ns (10 MHz) clock constraint:** works at 10, 50 and 75 MHz. One probe run at a higher clock failed (`accel_run returned -3` on all five layers, the STATUS error flag); the clock of that run was not recorded, it was probably the boot image's default of about 100 MHz, so where exactly the limit is between 75 and 100 MHz is not known. Which programs were run at 50 and 75 MHz is not recorded. This is an empirical result, not a timing-closed one: Vivado never checked that build against 50, 75 or 100 MHz, so these clocks have unknown margin and may change with the next build.
- **Whole network (2026-11-25):** a request of 75 MHz failed in layer `b2c2` (the probe had passed at that setting). A request of 70 MHz ran `camus_accel` bit-exact on 2 and on 5 frames: 33.803 s per frame (5 frames: mean 33,802.861 ms, min 33,802.670, max 33,803.083), 2,245,339,410 accelerator clocks per frame (5 frames; 2,245,340,565 with 2 frames, a difference of 0.00005 %), 60.1 per MAC. The command above therefore uses `70000000`, not `75000000`. The kernel rounds `set_rate` down to what the IO PLL dividers give (1000 MHz divided by an integer), so 70 MHz probably became 66.7 MHz (the numbers fit: 2,245,340,565 clocks in 33.68 s is 66.7 MHz, arithmetic) and 75 MHz probably 71.4 MHz *(check: read `set_rate` back after every change and write the value down)*. So this build works at 66.7 MHz and not at what was probably 71.4 MHz, which is marginal, and consistent with a build that was never timing-checked at these clocks.
- **Clocks per MAC depend on the clock.** They rose from 47.2 (10 MHz) to 60.1 (66.7 MHz), although the simulated clock counts of the old and the new RTL are the same (tiny_b: 454,190 vs 454,198 clocks, idealized memory). The reason is that the DDR path (SmartConnect, HP port, DDR controller) takes about the same *time* whatever the PL clock is, so at a faster clock the same wait costs more clocks. A two-point fit through the two measured runs gives about 45 clocks of logic plus about 230 ns of memory wait per MAC (arithmetic from two points, rough). A faster PL clock therefore has diminishing returns for v1: the wait for DDR, not the clock, sets the time. By the same fit 100 MHz would give about 25 s per frame and 200 MHz about 17 s (extrapolation, not measured). A clock is only trustworthy when the Timing Summary of the build shows that period and WNS is 0 or positive (see `vhdl/constraints/zed_fclk0_override.xdc`).

## 7. Run

```
cd /tmp/c
./armhf/accel_probe --regs 0x40000000 --mem 0x1F000000:0x1000000
./armhf/accel_golden ../build/export b3sc --regs 0x40000000 --mem 0x1F000000:0x1000000
./armhf/accel_golden ../build/export b2sc --regs 0x40000000 --mem 0x1F000000:0x1000000
./armhf/accel_golden ../build/export stem --regs 0x40000000 --mem 0x1F000000:0x1000000
./armhf/camus_accel ../build/export 2 --regs 0x40000000 --mem 0x1F000000:0x1000000
```
- To avoid typos, set the options once: `OPT="--regs 0x40000000 --mem 0x1F000000:0x1000000"`, then run `./armhf/accel_probe $OPT`, `./armhf/accel_golden ../build/export b3sc $OPT` and `./armhf/camus_accel ../build/export 2 $OPT`. Typical typos seen: `-mem` with one dash, `x` instead of `:` between address and size, a lost digit in `0x1F000000` (the program then says `both options are needed`).
- `--regs` is the base address of `s_axi` in the Address Editor (`0x4000_0000` for this block design), `--mem` is the reserved DDR range (`0x1F00_0000`, 16 MB).
- Write the size as `0x1000000`. A leading zero (`01000000`) is octal, which is only 256 KB: enough for `accel_probe`, not for the big layers or `camus_accel`.
- The other six golden layers are `b1c1 b1c2 b2c1 b2c2 b3c1 b3c2`, run the same way.
- Expected: `accel_probe` ends with `all checks pass`, every `accel_golden` says `bit-exact`, and `camus_accel` says `bit-exact vs test_logits.bin: yes`.
- Time per frame (measured): 176.5 s at 10 MHz (old address generation), 33.80 s at a 70 MHz request (about 66.7 MHz real, new address generation). Use 1 or 2 frames with `camus_accel`, not all 200 (at 33.8 s per frame all 200 would take almost two hours).

## 8. Stop

On the board:
```
sync
```
Do not use `exit` or `poweroff`: this shell is the init process, exiting it crashes the kernel. Then switch the board off with the power switch.

On the PC: stop the server with `Ctrl+C`, then
```powershell
Remove-NetFirewallRule -DisplayName "board http"
Remove-NetFirewallRule -DisplayName "board ping"
Remove-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 192.168.1.1
```

## 9. Quick fixes

| What you see | Cause | Fix |
|---|---|---|
| `Kernel panic ... Unable to mount root fs` after `boot` | `mem=496M` without `initrd_high` and `fdt_high` | type the four lines of section 2 |
| `MemTotal` about 513000 kB | `mem=496M` not in the boot arguments | redo section 2 |
| board `ping` to the PC fails, PC `ping` to the board works | Windows firewall | the two rules in section 1 |
| `wget: Connection refused` | server not running | start `python -m http.server` (section 1) |
| `prog_done` is not `1` | bitstream not accepted | `dmesg`, then convert with bootgen (section 5) |
| `/sys/class/fclk/fclk0/set_rate: No such file` | `fclk0` not exported | `echo fclk0 > $D/fclk_export` (section 6) |
| the shell stops responding at the probe | register read without bitstream or clock | *Reset*, repeat from section 2 |
| `accel_run returned -3` on every layer, registers read back fine | the PL clock is faster than the design can do (seen once at a clock above 75 MHz, probably the boot image's 100 MHz; the same bitstream worked at 10, 50 and 75 MHz) | lower the clock with `set_rate` (section 6); for a trustworthy faster clock rebuild with a real timing constraint and WNS >= 0 |
| `DMA range ... is full` | size written with a leading zero (octal) | `0x1000000` |
| the programs or the bitstream are gone after a Reset | `/tmp` is RAM | repeat section 4 after every Reset |
