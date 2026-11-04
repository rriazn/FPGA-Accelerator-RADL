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

# static ARMv7 binaries for the ZedBoard Cortex-A9, fallback if the board has no gcc
cross: armhf/camus_naive_O0 armhf/camus_naive_O2

armhf/camus_naive_%: camus_naive.c
	mkdir -p armhf
	$(CROSS)gcc $(CFLAGS) -$* -static -o $@ $<

# transfer package for the board, unpacks to c/ and build/export/
package: cross
	tar czf ../build/board.tar.gz --exclude=build/export/golden -C .. c/Makefile c/camus_naive.c c/board_run.sh c/armhf build/export

clean:
	rm -rf camus_naive_O0 camus_naive_O2 armhf
