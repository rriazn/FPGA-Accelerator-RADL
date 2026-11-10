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

# static ARMv7 binaries for the ZedBoard Cortex-A9, fallback if the board has no gcc
cross: armhf/camus_naive_O0 armhf/camus_naive_O2

armhf/camus_naive_%: camus_naive.c
	mkdir -p armhf
	$(CROSS)gcc $(CFLAGS) -$* -static -o $@ $<

# transfer package for the board, unpacks to c/ and build/export/
package: cross
	tar czf ../build/board.tar.gz --exclude=build/export/golden -C .. c/Makefile c/camus_naive.c c/board_run.sh c/armhf build/export

clean:
	rm -rf camus_naive_O0 camus_naive_O2 camus_accel accel_probe accel_golden armhf
