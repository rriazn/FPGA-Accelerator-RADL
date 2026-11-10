/* Picks the backend of a program from its command line, shared by camus_accel and accel_probe
 *   (no option)                      software stand-in (accel_sim.c)
 *   --regs <addr> --mem <addr>:<size>   board backend (board_platform.c), numbers in hex (0x...) or decimal
 * the two options are removed from argv, so the program parses what is left; it exits with a message on bad input */
#ifndef PLATFORM_CLI_H
#define PLATFORM_CLI_H

#include "accel.h"

/* returns the platform, *name is "stand-in" or "board" */
platform_t platform_open(int *argc, char **argv, const char **name);
void platform_close(void);

#endif
