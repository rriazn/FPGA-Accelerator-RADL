/* Board backend of the conv accelerator, see board_platform.h */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#include "board_platform.h"

struct board {
    int fd;
    volatile uint32_t *regs;
    void *regs_map;
    size_t page;
    uint8_t *mem;
    uint32_t mem_phys;
    size_t mem_size, used;
};

static void fatal(const char *msg) {
    perror(msg);
    exit(2);
}

static void reg_write(void *ctx, uint32_t off, uint32_t val) {
    board_t *b = ctx;
    __sync_synchronize(); /* the buffer writes before this are visible first, the start must not overtake them */
    b->regs[off >> 2] = val;
}

static uint32_t reg_read(void *ctx, uint32_t off) {
    board_t *b = ctx;
    return b->regs[off >> 2];
}

static dma_buf_t alloc_buf(void *ctx, size_t size) {
    board_t *b = ctx;
    size_t start = (b->used + 63) & ~(size_t)63;
    if (start + size > b->mem_size) {
        fprintf(stderr, "error: the DMA range of %zu bytes is full (%zu used, %zu more needed)\n", b->mem_size, b->used, size);
        exit(2);
    }
    b->used = start + size;
    dma_buf_t d = {b->mem + start, b->mem_phys + (uint32_t)start, size};
    return d;
}

/* the mapping is uncached, only the order of the accesses matters */
static void sync_buf(void *ctx, const dma_buf_t *d) {
    (void)ctx;
    (void)d;
    __sync_synchronize();
}

board_t *board_open(uint32_t regs_phys, uint32_t mem_phys, size_t mem_size) {
    board_t *b = calloc(1, sizeof *b);
    b->page = (size_t)sysconf(_SC_PAGESIZE);
    if (mem_phys % b->page) {
        fprintf(stderr, "error: the DMA range 0x%x is not page aligned\n", mem_phys);
        exit(2);
    }
    if (!mem_size || (uint64_t)mem_phys + mem_size > 0x100000000ull) {
        fprintf(stderr, "error: the DMA range 0x%x + 0x%zx does not fit in 32 bits\n", mem_phys, mem_size);
        exit(2);
    }
    b->fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (b->fd < 0) fatal("open /dev/mem");

    size_t in_page = regs_phys % b->page;
    if (in_page + 0x44 > b->page) {
        fprintf(stderr, "error: the registers at 0x%x cross a page\n", regs_phys);
        exit(2);
    }
    b->regs_map = mmap(NULL, b->page, PROT_READ | PROT_WRITE, MAP_SHARED, b->fd, regs_phys - in_page);
    if (b->regs_map == MAP_FAILED) fatal("mmap registers");
    b->regs = (volatile uint32_t *)((uint8_t *)b->regs_map + in_page);

    b->mem = mmap(NULL, mem_size, PROT_READ | PROT_WRITE, MAP_SHARED, b->fd, mem_phys);
    if (b->mem == MAP_FAILED) fatal("mmap DMA range");
    b->mem_phys = mem_phys;
    b->mem_size = mem_size;
    return b;
}

void board_close(board_t *b) {
    munmap(b->regs_map, b->page);
    munmap(b->mem, b->mem_size);
    close(b->fd);
    free(b);
}

platform_t board_platform(board_t *b) {
    platform_t p = {b, reg_write, reg_read, alloc_buf, sync_buf, sync_buf};
    return p;
}
