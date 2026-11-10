/* Picks the backend of a program from its command line, see platform_cli.h */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "accel_sim.h"
#include "board_platform.h"
#include "platform_cli.h"

#define SIM_ARENA (8u << 20)

static sim_t *g_sim;
static board_t *g_board;

static void usage_die(const char *msg, const char *arg) {
    fprintf(stderr, "error: %s %s\n(--regs <addr> --mem <addr>:<size>, both or none)\n", msg, arg);
    exit(2);
}

static unsigned long long number(const char *s, const char *what) {
    char *end;
    unsigned long long v = strtoull(s, &end, 0);
    if (end == s || *end) usage_die("bad number for", what);
    return v;
}

platform_t platform_open(int *argc, char **argv, const char **name) {
    const char *regs = NULL, *mem = NULL;
    int n = 1;
    for (int i = 1; i < *argc; i++) {
        if (!strcmp(argv[i], "--regs") || !strcmp(argv[i], "--mem")) {
            if (i + 1 >= *argc) usage_die("missing value after", argv[i]);
            if (!strcmp(argv[i], "--regs")) regs = argv[i + 1];
            else mem = argv[i + 1];
            i++;
        } else {
            argv[n++] = argv[i];
        }
    }
    *argc = n;

    if (!regs && !mem) {
        *name = "stand-in";
        g_sim = sim_create(SIM_ARENA);
        return sim_platform(g_sim);
    }
    if (!regs || !mem) usage_die("both options are needed:", regs ? "--mem" : "--regs");
    char *colon = strchr(mem, ':');
    if (!colon) usage_die("--mem needs <addr>:<size>, got", mem);
    char base[32];
    if ((size_t)(colon - mem) >= sizeof base) usage_die("bad --mem", mem);
    memcpy(base, mem, colon - mem);
    base[colon - mem] = 0;
    unsigned long long regs_phys = number(regs, "--regs"), mem_phys = number(base, "--mem address");
    unsigned long long mem_size = number(colon + 1, "--mem size");
    if (regs_phys > 0xFFFFFFFFull || mem_phys > 0xFFFFFFFFull) usage_die("address does not fit in 32 bits:", mem);
    *name = "board";
    g_board = board_open((uint32_t)regs_phys, (uint32_t)mem_phys, (size_t)mem_size);
    return board_platform(g_board);
}

void platform_close(void) {
    if (g_sim) sim_destroy(g_sim);
    if (g_board) board_close(g_board);
    g_sim = NULL;
    g_board = NULL;
}
