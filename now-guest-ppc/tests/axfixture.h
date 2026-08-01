#ifndef NOW_AX_FIXTURE_H
#define NOW_AX_FIXTURE_H

/* A synthetic big-endian classic-Mac heap for the axwalk tests.

   The walk's whole safety story is that it refuses to dereference
   anything outside two named regions, so a test needs to be able to
   place bytes at chosen ADDRESSES and to place them just outside as
   well. Two arenas stand in for the target process's partition and the
   system heap; the seam's reader resolves an address to whichever arena
   contains it and refuses everything else, exactly as a bus error would
   on the machine but survivably.

   Big-endian writers are explicit because the host running these tests
   is little-endian and the structures being parsed are not. A test that
   wrote host-order words would pass against a parser that read
   host-order words, which is precisely the bug worth catching. */

#include <string.h>

#include "axwalk.h"

#define AXFIX_TARGET_BASE 0x00100000UL
#define AXFIX_TARGET_SIZE 0x00010000UL
#define AXFIX_SYSTEM_BASE 0x00400000UL
#define AXFIX_SYSTEM_SIZE 0x00004000UL

typedef struct {
    unsigned char target[AXFIX_TARGET_SIZE];
    unsigned char system[AXFIX_SYSTEM_SIZE];
    int           reads;          /* how many times the seam was entered */
    int           refused;        /* reads the ARENA refused (never the
                                     walker: those never reach here) */
} AxFixture;

static inline unsigned char *axfix_at(AxFixture *f, unsigned long addr,
                                     size_t len)
{
    if (addr >= AXFIX_TARGET_BASE
        && addr + len <= AXFIX_TARGET_BASE + AXFIX_TARGET_SIZE) {
        return f->target + (addr - AXFIX_TARGET_BASE);
    }
    if (addr >= AXFIX_SYSTEM_BASE
        && addr + len <= AXFIX_SYSTEM_BASE + AXFIX_SYSTEM_SIZE) {
        return f->system + (addr - AXFIX_SYSTEM_BASE);
    }
    return 0;
}

static inline int axfix_read(void *ctx, unsigned long addr, void *out,
                             size_t len)
{
    AxFixture     *f = (AxFixture *)ctx;
    unsigned char *p = axfix_at(f, addr, len);

    f->reads++;
    if (p == 0) {
        f->refused++;
        return 0;
    }
    memcpy(out, p, len);
    return 1;
}

static inline void axfix_init(AxFixture *f, NowAxMemory *m)
{
    memset(f, 0, sizeof(*f));
    m->read = axfix_read;
    m->ctx = f;
    m->target_lo = AXFIX_TARGET_BASE;
    m->target_hi = AXFIX_TARGET_BASE + AXFIX_TARGET_SIZE;
    m->system_lo = AXFIX_SYSTEM_BASE;
    m->system_hi = AXFIX_SYSTEM_BASE + AXFIX_SYSTEM_SIZE;
}

static inline void axfix_put8(AxFixture *f, unsigned long addr, unsigned v)
{
    unsigned char *p = axfix_at(f, addr, 1);

    if (p != 0) {
        p[0] = (unsigned char)v;
    }
}

static inline void axfix_put16(AxFixture *f, unsigned long addr, int v)
{
    unsigned char *p = axfix_at(f, addr, 2);

    if (p != 0) {
        p[0] = (unsigned char)(((unsigned)v >> 8) & 0xffU);
        p[1] = (unsigned char)((unsigned)v & 0xffU);
    }
}

static inline void axfix_put32(AxFixture *f, unsigned long addr,
                              unsigned long v)
{
    unsigned char *p = axfix_at(f, addr, 4);

    if (p != 0) {
        p[0] = (unsigned char)((v >> 24) & 0xffUL);
        p[1] = (unsigned char)((v >> 16) & 0xffUL);
        p[2] = (unsigned char)((v >> 8) & 0xffUL);
        p[3] = (unsigned char)(v & 0xffUL);
    }
}

/* A Pascal string at `addr`. */
static inline void axfix_put_pstr(AxFixture *f, unsigned long addr,
                                 const char *s)
{
    size_t n = strlen(s);
    size_t i;

    axfix_put8(f, addr, (unsigned)n);
    for (i = 0; i < n; i++) {
        axfix_put8(f, addr + 1 + i, (unsigned char)s[i]);
    }
}

/* A Handle at `handle` pointing at `data` - the master-pointer
   indirection every classic structure hides behind. */
static inline void axfix_put_handle(AxFixture *f, unsigned long handle,
                                   unsigned long data)
{
    axfix_put32(f, handle, data);
}

/* A Region whose bounding box is the given rect. */
static inline void axfix_put_region(AxFixture *f, unsigned long addr,
                                   int t, int l, int b, int r)
{
    axfix_put16(f, addr, 10);
    axfix_put16(f, addr + 2, t);
    axfix_put16(f, addr + 4, l);
    axfix_put16(f, addr + 6, b);
    axfix_put16(f, addr + 8, r);
}

#endif /* NOW_AX_FIXTURE_H */
