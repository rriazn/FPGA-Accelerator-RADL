CC ?= gcc
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

clean:
	rm -f camus_naive_O0 camus_naive_O2
