CC ?= gcc
CROSS ?= arm-linux-gnueabihf-
CFLAGS = -std=c11 -D_POSIX_C_SOURCE=200809L -Wall -Wextra
EXPORT ?= ../build/export

all: camus_naive_O0 camus_naive_O2

camus_naive_O0: camus_naive.c
	$(CC) $(CFLAGS) -O0 -o $@ $<

camus_naive_O2: camus_naive.c
	$(CC) $(CFLAGS) -O2 -o $@ $<

run: all
	./camus_naive_O0 $(EXPORT)
	./camus_naive_O2 $(EXPORT)

# ARM side with the conv layers on the accelerator, today the software stand-in (accel_sim.c)
# with --regs and --mem the same programs run on the board through /dev/mem (board_platform.c), see README
ACCEL_SRC = accel.c accel_sim.c board_platform.c platform_cli.c
ACCEL_HDR = accel.h accel_regs.h accel_sim.h board_platform.h platform_cli.h
ACCEL_FLAGS = -D_FILE_OFFSET_BITS=64

camus_accel: camus_accel.c $(ACCEL_SRC) $(ACCEL_HDR)
	$(CC) $(CFLAGS) $(ACCEL_FLAGS) -O2 -o $@ camus_accel.c $(ACCEL_SRC)

accel_probe: accel_probe.c $(ACCEL_SRC) $(ACCEL_HDR)
	$(CC) $(CFLAGS) $(ACCEL_FLAGS) -O2 -o $@ accel_probe.c $(ACCEL_SRC)

accel_golden: accel_golden.c $(ACCEL_SRC) $(ACCEL_HDR)
	$(CC) $(CFLAGS) $(ACCEL_FLAGS) -O2 -o $@ accel_golden.c $(ACCEL_SRC)

GOLDEN_LAYERS = stem b1c1 b1c2 b2c1 b2c2 b2sc b3c1 b3c2 b3sc

run-accel: camus_accel accel_probe accel_golden
	./accel_probe
	set -e; for l in $(GOLDEN_LAYERS); do ./accel_golden $(EXPORT) $$l; done
	./camus_accel $(EXPORT)

# static ARMv7 builds of the programs above for the board (not part of cross and package)
cross-accel: armhf/camus_accel armhf/accel_probe armhf/accel_golden

armhf/camus_accel armhf/accel_probe armhf/accel_golden: armhf/%: %.c $(ACCEL_SRC) $(ACCEL_HDR)
	mkdir -p armhf
	$(CROSS)gcc $(CFLAGS) $(ACCEL_FLAGS) -O2 -static -o $@ $< $(ACCEL_SRC)

# transfer package of the accelerator programs for the ZedBoard: armhf binaries, the export and golden frame f000,
# unpacks to c/ and build/export/ (the older package target has the naive baseline and leaves the golden files out)
package-accel: cross-accel
	tar czf ../build/board-accel.tar.gz --exclude=build/export/golden/f016 -C .. c/Makefile c/armhf/camus_accel c/armhf/accel_probe c/armhf/accel_golden c/accel.c c/accel.h c/accel_regs.h c/accel_sim.c c/accel_sim.h c/board_platform.c c/board_platform.h c/platform_cli.c c/platform_cli.h c/accel_probe.c c/accel_golden.c c/camus_accel.c build/export

# static aarch64 builds of the same programs for the Ultra96 (Cortex-A53), needs aarch64-linux-gnu-gcc (not in the
# radl-tf1 image: apt-get install gcc-aarch64-linux-gnu); output in aarch64/
CROSS64 ?= aarch64-linux-gnu-

cross-accel64: aarch64/camus_accel aarch64/accel_probe aarch64/accel_golden

aarch64/camus_accel aarch64/accel_probe aarch64/accel_golden: aarch64/%: %.c $(ACCEL_SRC) $(ACCEL_HDR)
	mkdir -p aarch64
	$(CROSS64)gcc $(CFLAGS) $(ACCEL_FLAGS) -O2 -static -o $@ $< $(ACCEL_SRC)

# transfer package of the accelerator programs for the Ultra96: aarch64 binaries, the export and golden frame f000,
# unpacks to c/ and build/export/
package64: cross-accel64
	tar czf ../build/board64.tar.gz --exclude=build/export/golden/f016 -C .. c/Makefile c/aarch64 c/accel.c c/accel.h c/accel_regs.h c/accel_sim.c c/accel_sim.h c/board_platform.c c/board_platform.h c/platform_cli.c c/platform_cli.h c/accel_probe.c c/accel_golden.c c/camus_accel.c build/export

# static ARMv7 binaries for the ZedBoard Cortex-A9, fallback if the board has no gcc
cross: armhf/camus_naive_O0 armhf/camus_naive_O2

armhf/camus_naive_%: camus_naive.c
	mkdir -p armhf
	$(CROSS)gcc $(CFLAGS) -$* -static -o $@ $<

# transfer package for the board, unpacks to c/ and build/export/
package: cross
	tar czf ../build/board.tar.gz --exclude=build/export/golden -C .. c/Makefile c/camus_naive.c c/board_run.sh c/armhf build/export

clean:
	rm -rf camus_naive_O0 camus_naive_O2 camus_accel accel_probe accel_golden armhf aarch64
