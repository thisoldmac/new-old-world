/*
 * axpeek.c - TBT AXPeek: a resident INIT that gives agents cross-app UI
 * observation, the accessibility API classic Mac OS never had (docs/41).
 *
 * The A5-world barrier: the Window/Control/Menu Managers keep per-process state
 * in low-memory globals swapped on every context switch, so the harness — from
 * its own process — can only ever see its own UI, never the front app's. The
 * one OS-abstraction way to read a foreign app's UI is to run *in that app's
 * context*. This INIT installs a GetNextEvent filter, which runs synchronously
 * in the calling app's A5 world. It records the process-local memory anchors in
 * a system-heap buffer (AXShared) whose address is published via
 * Gestalt('TBax'); a normal-context reader maps those anchors to a public
 * Process Manager partition and walks that app's WindowList directly.
 *
 * Read-only by contract: this INIT observes and publishes, never actuates. All
 * clicking/typing stays in the harness. The blast radius is asymmetric on
 * purpose (docs/41 "Safety posture"). A bug here crashes the whole machine, so
 * this is emu-only until the validation ladder's Gate 4 is solid.
 *
 * This remains emulator-only until two unknowns are proved: that a boot-time
 * filter is inherited by application contexts on the target System release,
 * and that the relocated flat blob is safe when entered from another A5 world.
 */

#include <Events.h>
#include <Files.h>
#include <Gestalt.h>
#include <LowMem.h>
#include <MacMemory.h>
#include <OSUtils.h>
#include <Processes.h>
#include <Resources.h>
#include <Retro68Runtime.h>

#include "axoracle.h"

extern void ax_gne_filter(void);

/* Read by the assembly tail-chain after it restores the incoming register
 * state. This symbol must remain externally visible to axgne.S. */
GetNextEventFilterUPP gOldGNEFilter = NULL;

/* Read by axgne.S's hot path. A process switch or WindowList-root change
 * samples immediately; an unchanged context refreshes every six ticks. */
unsigned long gLastA5 = 0;
unsigned long gLastWindowList = 0;
unsigned long gLastTicks = 0;

/* ---- boot log (sprcache pattern): a legible trace at the boot volume root,
 * read back with the harness `read` verb or hfsutils. Gate-1 debugging only. */
static short g_lref = 0, g_lvref = 0;

static void log_open(void)
{
    FSSpec spec;

    if (GetVol(NULL, &g_lvref) != noErr) {
        g_lvref = 0;
    }
    if (FSMakeFSSpec(g_lvref, fsRtDirID, "\ptbt-axpeek.txt", &spec) == noErr) {
        (void)FSpDelete(&spec);
    }
    if (FSpCreate(&spec, 'ttxt', 'TEXT', 0) != noErr) {
        return;
    }
    if (FSpOpenDF(&spec, fsWrPerm, &g_lref) != noErr) {
        g_lref = 0;
    }
}

static void log_hex(const char *name, unsigned long v)
{
    char buf[48];
    int  i = 0, d;
    long n;

    if (g_lref == 0) {
        return;
    }
    while (name[i] != '\0') {
        buf[i] = name[i];
        i++;
    }
    buf[i++] = '=';
    buf[i++] = '0';
    buf[i++] = 'x';
    for (d = 28; d >= 0; d -= 4) {
        buf[i++] = "0123456789abcdef"[(v >> d) & 0xF];
    }
    buf[i++] = '\n';
    n = i;
    (void)FSWrite(g_lref, &n, (Ptr)buf);
    (void)FlushVol(NULL, g_lvref);
}

static void log_close(void)
{
    if (g_lref != 0) {
        (void)FSClose(g_lref);
        (void)FlushVol(NULL, g_lvref);
        g_lref = 0;
    }
}

/*
 * Resident globals. These live in the relocated flat blob, addressed as
 * absolute (relocated) locations — NOT A5-relative — so they resolve from any
 * context, including interrupt time. Validity after boot depends on the blob
 * staying put: the 'INIT' resource is loaded locked in the system heap (see
 * AXPeek.r) and DetachResource keeps it from being disposed, so it never moves.
 * We deliberately do NOT call Retro68FreeGlobals().
 *
 * The writer runs synchronously from the GetNextEvent filter. Unlike the
 * rejected Time Manager sampler, it never invokes Toolbox code at interrupt
 * time. axgne.S preserves the incoming registers, calls ax_gne_sample, restores
 * them, and tail-jumps to the original filter.
 */
static AXShared *gBuf = NULL;

/* ---- shared buffer (seqlock writer) -------------------------------------- */

/* Called by axgne.S in normal event-loop context. Keep this bounded and
 * allocation-free: it samples raw low-memory values and at most 32 slots. */
void ax_gne_sample(void)
{
    AXShared     *buf = gBuf;
    unsigned long currentA5 = (unsigned long)LMGetCurrentA5();
    unsigned long stackBase = (unsigned long)LMGetCurStackBase();
    unsigned long windowList = (unsigned long)LMGetWindowList();
    unsigned long menuList = (unsigned long)LMGetMenuList();
    unsigned long now = (unsigned long)LMGetTicks();

    if (buf != NULL) {
        /* seqlock: odd => write in progress. Bracket the body so a concurrent
         * reader either retries or sees a whole snapshot. */
        buf->seq++;                             /* -> odd */
        __asm__ volatile ("" ::: "memory");

        buf->ticks = now;
        buf->calls++;                           /* committed samples */
        buf->lastTrap = 0;                      /* GNEFilter, not a trap patch */
        (void)ax_oracle_record(buf, currentA5, stackBase, windowList, menuList,
                               now, (const unsigned char *)0x0910L);
        gLastA5 = currentA5;
        gLastWindowList = windowList;
        gLastTicks = now;
        buf->lastErr = 0;

        __asm__ volatile ("" ::: "memory");
        buf->seq++;                             /* -> even, snapshot complete */
    }
}

/* ---- Gestalt publisher --------------------------------------------------- */

/* Hand the resident buffer's address to anyone (the harness) that asks for
 * Gestalt('TBax'). Resident like everything else in the blob. */
static pascal OSErr ax_gestalt(OSType selector, long *response)
{
#pragma unused(selector)
    *response = (long)gBuf;
    return noErr;
}

/* ---- install ------------------------------------------------------------- */

void _start(void)
{
    Handle                     self;
    SelectorFunctionUPP        gestaltUPP;
    OSErr                      err;

    RETRO68_RELOCATE();
    Retro68CallConstructors();

    /* Stay resident: detach our own code resource so closing the extension
     * file does not dispose it. It is loaded locked+sysHeap (AXPeek.r), so it
     * will not move and the relocation above stays valid. */
    log_open();
    log_hex("axpeek", AX_VERSION);

    self = Get1Resource('INIT', 128);
    log_hex("selfrsrc", (unsigned long)self);
    if (self == NULL) {
        log_close();
        return;
    }
    DetachResource(self);

    /* Publish the shared buffer. NewPtrSys => system heap => addressable from
     * every process, including the harness. */
    gBuf = (AXShared *)NewPtrSysClear((Size)sizeof(AXShared));
    if (gBuf == NULL) {
        log_hex("buf", 0);
        log_close();
        return;                                 /* no buffer: install nothing */
    }
    gBuf->version = AX_VERSION;
    gBuf->magic   = AX_MAGIC;                    /* magic last: liveness flag */
    log_hex("buf", (unsigned long)gBuf);

    gestaltUPP = NewSelectorFunctionUPP(ax_gestalt);
    err = NewGestalt(AX_GESTALT, gestaltUPP);
    if (err != noErr) {
        log_hex("gesterr", (unsigned long)(unsigned short)err);
        DisposeSelectorFunctionUPP(gestaltUPP);
        DisposePtr((Ptr)gBuf);
        gBuf = NULL;
        log_close();
        return;
    }

    /* On classic 68K a GetNextEventFilterUPP is a raw ProcPtr. The hook has a
     * special register ABI, so ax_gne_filter is an assembly shim rather than a
     * C callback. It tail-chains the filter that was present at boot. */
    gOldGNEFilter = LMGetGNEFilter();
    LMSetGNEFilter((GetNextEventFilterUPP)ax_gne_filter);
    log_hex("oldgne", (unsigned long)gOldGNEFilter);
    log_hex("newgne", (unsigned long)ax_gne_filter);
    log_close();

    /* Intentionally NOT calling Retro68FreeGlobals(): the buffer, old-filter
     * pointer, and assembly shim must remain resident for the machine lifetime. */
}
