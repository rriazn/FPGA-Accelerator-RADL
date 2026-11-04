# How to connect to the board

## Step 1: Prepare the board
- Connect UART, power
- put in SD card (NO ADAPTER), not set to read only
- JP6 Cap on
- JP7, 8, 11 GND
- JP9, 10 3V3

## Step 2: Prepare the PC (Windows)
- Connect the Micro USB to the PC
- use ```[System.IO.Ports.SerialPort]::GetPortNames()``` to find out the port
- Open putty, select *Serial*, the port and baud *115200*
- Connect the Board and PC with an ethernet cable and run 
```ps
New-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 192.168.1.1 -PrefixLength 24
```
- (reset it later with ```Remove-NetIPAddress -InterfaceAlias "Ethernet" -IPAddress 192.168.1.1```)

## Step 2: Prepare the PC (Ubuntu)
Tested on 2026-11-04. Connect the Micro USB and the ethernet cable, then run these on the PC.

One-time setup:
```bash
sudo usermod -aG dialout $USER
sudo nmcli connection add type ethernet ifname enp7s0 con-name zedboard autoconnect no ipv4.method manual ipv4.addresses 192.168.1.1/24 ipv4.never-default yes ipv6.method disabled
```
- `enp7s0` is the ethernet adapter on the laptop used here; check yours with `ip -br addr`
- WiFi stays the default route, so the internet keeps working
- `dialout` takes effect at the next login. Until then, keep the `sg dialout -c` in the command below
- (remove the profile later with `sudo nmcli connection delete zedboard`)

Find the port and open the console:
```bash
ls -l /dev/serial/by-id/
sg dialout -c 'screen -L -Logfile ~/board-session.log /dev/serial/by-id/usb-2012_Cypress_Semiconductor_Cypress-USB2UART-Ver1.0G_846405032008-if00 115200'
```
- Use the `by-id` name. The port is a `/dev/ttyACM*` device and its number can change
- Quit `screen` with `Ctrl+A`, then `k`, then `y`
- `~/board-session.log` keeps the console output on the PC
- Only one program can use the port at a time; a second one takes part of the output

## Step 3: Boot on the board
- ensure the SD card is in
- power on
- connect on the pc via putty
- hit the *Reset* button on the board
- Boot text should appear in the console
- Wait for a bit
- Hit *Reset* again and press any key on the pc
- You land in U-Boot. Run 
```sh
setenv bootargs console=ttyPS0,115200 rdinit=/bin/sh init=/bin/sh
boot
```
- The countdown is only 3 seconds, so start pressing Enter right after *Reset*. The prompt must read `zynq-uboot>` before you type `setenv`
- Use *Reset*, not the power switch, to get to U-Boot. On Ubuntu the power switch also disconnects the USB port for a few seconds, so you miss the countdown and have to reopen `screen`
- When `sh-4.3#` appears, run:
```sh
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs devtmpfs /dev
```
- `Ctrl+C` does not work in this shell. A stuck command can only be ended with *Reset*

## Step 4: Copy files to the board
- run this on the board: 
```
ifconfig eth0 192.168.1.10 netmask 255.255.255.0 up
```
- run a python server on the project root:
```python -m http.server 8000 --directory build```
- use wget to copy files, e.g.:
```wget http://192.168.1.1:8000/board.tar.gz
tar xzf board.tar.gz```

### On Ubuntu
1. On the board, run the `ifconfig` line above. This takes the ethernet link down for up to about 15 seconds.
2. Then on the PC, bring the profile up. Do this after every `ifconfig` or power cycle, because the profile drops when the link goes down:
```bash
sudo nmcli connection up zedboard
ip -br addr show enp7s0     # must show 192.168.1.1/24
```
3. On the board, test the link before using `wget`, because a stuck `wget` cannot be interrupted:
```sh
ping -c 3 192.168.1.1
```
4. On the PC, build the package if `build/board.tar.gz` is missing. From the project root (Docker here needs `sudo`; the file should be about 2.1 MB):
```bash
sudo docker run --rm -v "$PWD:/work" -w /work/c radl-tf1 make package
```
5. On the PC, start the server. Binding to `192.168.1.1` keeps it off WiFi. Stop it with `Ctrl+C` when you are done:
```bash
python3 -m http.server 8000 --bind 192.168.1.1 --directory build
```
6. On the board:
```sh
cd /tmp; wget http://192.168.1.1:8000/board.tar.gz; tar xzf board.tar.gz; cd c; ls armhf
```
`/tmp` is in RAM, so repeat this after every reset.

## Step 5: Stop the board
Linux runs from RAM, so the board can be switched off once the SD card is safe.

Print anything you want to keep first: `/tmp` is erased at power off, including `results_*`. The `screen` log (or PuTTY session log) keeps what was printed.

On the board:
```sh
mount | grep mmcblk     # if this lists anything, run umount on its mount point, e.g. umount /mnt
sync
```
- Do not use `exit` or `poweroff`. This shell is the system's init process: exiting it crashes the kernel, and `poweroff` may not work without a normal init

On the PC:
- Ubuntu: quit `screen` (`Ctrl+A`, then `k`, then `y`), stop the server with `Ctrl+C`, then run `sudo nmcli connection down zedboard`
- Windows: close PuTTY, stop the server with `Ctrl+C`, and remove the IP address (see Step 2)

Then switch the board off with the power switch and unplug the cables.

## Problems on Ubuntu
| What you see | Cause | Fix |
|---|---|---|
| `Permission denied` on the serial port | Not in `dialout` yet | Use `sg dialout -c '...'` or log in again |
| `/dev/serial/by-id/` is missing, or `error -71` in `journalctl -k` | USB port not connected or not responding | Plug the cable in firmly, or try another USB port or cable |
| `setenv: command not found` | You are in Linux, not U-Boot | If the prompt is `sh-4.3#`, skip `setenv`. Otherwise press *Reset* and try again |
| `sudo: command not found` on the board | A PC command was typed into the board console | Run it in a PC terminal |
| `ip -br addr` shows no `192.168.1.1/24` | The `zedboard` profile dropped and the PC is trying DHCP | `sudo nmcli connection up zedboard` |
| `wget: ... Connection refused` | The link works, but the server is not running | Start the server (Step 4, On Ubuntu) |
| `ping` or `wget` gets no answer, and `cat /sys/class/net/eth0/speed` on the board shows `1000` | Not confirmed, see below | See below |
| A `board_run.sh` run shows no results and no prompt | The console output stopped; the run itself can still finish. Cause not confirmed | Press Enter, then read the results with `cat results_*` |
| `make: *** No rule to make target 'package'` | Not run from the project root | `cd` to the project root |
| `arm-linux-gnueabihf-gcc: Command not found` | The Docker image is older than the Dockerfile | `sudo docker build -t radl-tf1 python` from the project root |

**No traffic at 1 Gb/s.** On 2026-11-04, traffic failed twice at 1 Gb/s with the profile up. It worked once the link came up at 100 Mb/s by itself, and the cause is not confirmed. If this happens again, try limiting the PC to 100 Mb/s, which has not been tested yet:
```bash
sudo ethtool -s enp7s0 speed 100 duplex full autoneg on
sudo nmcli connection up zedboard
```
(undo with `sudo ethtool -s enp7s0 speed 1000 duplex full autoneg on`)
