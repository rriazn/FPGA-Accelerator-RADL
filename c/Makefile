CC ?= gcc
CROSS ?= aarch64-linux-gnu-
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

# static aarch64 binaries, fallback if the board has no gcc
cross: aarch64/camus_naive_O0 aarch64/camus_naive_O2

aarch64/camus_naive_%: camus_naive.c
	mkdir -p aarch64
	$(CROSS)gcc $(CFLAGS) -$* -static -o $@ $<

# transfer package for the board, unpacks to c/ and build/export/
package: cross
	tar czf ../build/board.tar.gz --exclude=build/export/golden -C .. c/Makefile c/camus_naive.c c/board_run.sh c/aarch64 build/export

clean:
	rm -rf camus_naive_O0 camus_naive_O2 aarch64
