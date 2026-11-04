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
