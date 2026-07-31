/*
 * qdprobe.c - QD Probe: a throwaway INIT that patches ONE QuickDraw
 * bottleneck and counts calls through it.
 *
 * NOT a NOW component. See README.md: this is the P3 spike, developed
 * under its own name with its own Gestalt selector so that a crash here
 * cannot be a crash in the shipping extension. Delete it when its
 * questions are answered.
 *
 * The question: can a 68K INIT's drawing bottleneck be called safely by
 * a PowerPC application's QuickDraw? NOW's jGNE filter is no evidence -
 * the Event Manager calls that as bare 68K code, while QuickDraw's
 * bottleneck is invoked by whatever is drawing, which under CarbonLib is
 * native PowerPC and therefore goes through Mixed Mode. This project
 * froze a PowerBook once already getting that distinction wrong.
 *
 * So: one bottleneck, a counter, and a disposable clone.
 */

#include <Gestalt.h>
#include <LowMem.h>
#include <MacMemory.h>
#include <Quickdraw.h>
#include <Resources.h>
#include <Retro68Runtime.h>
#include <Traps.h>

#define QDPROBE_4CC(a, b, c, d)                                       \
    (((unsigned long)(a) << 24) | ((unsigned long)(b) << 16)          \
     | ((unsigned long)(c) << 8) | (unsigned long)(d))

enum {
    /* Ours, and deliberately not 'NWex' (NOW's) or 'TBqd' (tbt's). */
    kQDProbeGestalt = (long)QDPROBE_4CC('Q', 'D', 'p', 'r'),
    kQDProbeMagic = (long)QDPROBE_4CC('Q', 'D', 'p', 'r'),

    /* Ports patched at once. Small on purpose: this is a spike, and a
       bigger table would only mean more to unwind if it goes wrong. */
    kQDProbeMaxPorts = 8
};

/* One patched port. `a5` is the context the patch was made in and is the
   gate on ever touching this port again - see restore_ports(). */
typedef struct {
    unsigned long port;           /* CGrafPtr, as a plain address */
    unsigned long saved_procs;    /* the port's grafProcs before us */
    unsigned long a5;             /* LMGetCurrentA5() when patched */
    CQDProcs procs;               /* OUR block; lives in the system heap */
} QDProbePort;

/* Published through Gestalt. Plain 32-bit fields, big-endian machine,
   one writer - the same discipline as NOW's table, minus the versioning,
   because nothing ships this. */
typedef struct {
    unsigned long magic;
    unsigned long heartbeat;      /* TickCount at last jGNE pass */
    unsigned long arm;            /* WRITTEN BY A READER: nonzero = patch */
    unsigned long armed_ports;    /* entries currently patched */
    unsigned long rect_calls;     /* THE ANSWER: calls through our proc */
    unsigned long patches;        /* successful installs */
    unsigned long restores;       /* successful removals */
    unsigned long skipped;        /* ports we declined to patch */
    unsigned long stranded;       /* entries we refused to restore */
} QDProbeShared;

static QDProbeShared *gShared = NULL;
static QDProbePort gPorts[kQDProbeMaxPorts];
static short gPortCount;

GetNextEventFilterUPP gQDProbeOldGNEFilter = NULL;
extern void qdprobe_gne_filter(void);

/* The patched bottleneck. Counts, then tail-calls the proc that was
   there before us - never replaces the drawing, only observes it. The
   port passed to a bottleneck is always the CURRENT port, so thePort is
   how we find our own entry.

   Called from a foreign process's drawing code. Allocates nothing, calls
   nothing that moves memory, and touches only the system-heap block and
   its own table. */
static pascal void qdprobe_rect(GrafVerb verb, const Rect *r)
{
    GrafPtr gp;
    unsigned long port;
    short i;

    /* GetPort(), NOT the `qd` globals. Resident code has no QuickDraw
       globals of its own: `qd` is an application's A5-based struct that
       InitGraf fills in, and an INIT never calls InitGraf, so `qd.thePort`
       here reads our own relocated BSS and is whatever was there at boot.
       It links and it compiles - the object file showed a live reference
       to `qd` - which is the entire reason this was worth checking rather
       than trusting the clean build. GetPort asks the Toolbox, in the
       current context, and is correct from anywhere. */
    GetPort(&gp);
    port = (unsigned long)gp;

    if (gShared != NULL) {
        ++gShared->rect_calls;
    }
    for (i = 0; i < gPortCount; ++i) {
        if (gPorts[i].port == port && gPorts[i].saved_procs != 0) {
            CQDProcs *prev = (CQDProcs *)gPorts[i].saved_procs;

            if (prev->rectProc != NULL) {
                CallQDRectProc(prev->rectProc, verb, r);
            }
            return;
        }
    }
    /* Our proc on a port we have no record of: draw nothing rather than
       guess at a chain we are not on. Visible as a missing rectangle,
       which is a bug report; guessing is a corrupted screen. */
}

static short find_port(unsigned long port)
{
    short i;

    for (i = 0; i < gPortCount; ++i) {
        if (gPorts[i].port == port) {
            return i;
        }
    }
    return -1;
}

/* Patch the current port, if it is one we can safely patch. */
static void patch_current_port(void)
{
    GrafPtr gp;
    CGrafPtr cp;
    QDProbePort *e;

    GetPort(&gp);
    if (gp == NULL) {
        return;
    }
    cp = (CGrafPtr)gp;
    /* Color ports only. A classic GrafPort's grafProcs is a QDProcs, a
       DIFFERENT and shorter structure, and installing a CQDProcs over it
       would hand QuickDraw the wrong layout - the silent-corruption
       version of this mistake rather than the loud one. The high bit of
       portVersion marks a CGrafPort. */
    if ((cp->portVersion & 0xC000) != 0xC000) {
        ++gShared->skipped;
        return;
    }
    if (find_port((unsigned long)cp) >= 0) {
        return;                       /* already ours */
    }
    if (gPortCount >= kQDProbeMaxPorts) {
        ++gShared->skipped;
        return;
    }
    /* A port that already has custom grafProcs belongs to something else
       - another extension, or the application's own drawing. Chaining
       onto a stranger is how two of these fight over one port and one of
       them loses the machine. Leave it. */
    if (cp->grafProcs != NULL) {
        ++gShared->skipped;
        return;
    }
    e = &gPorts[gPortCount];
    /* SetStdCProcs fills our block with the standard bottlenecks, so
       every proc but ours is the real one and drawing is unchanged. */
    SetStdCProcs(&e->procs);
    /* On this toolchain NewQDRectUPP is a plain cast, NOT a routine
       descriptor - confirmed by the object file carrying no reference to
       NewRoutineDescriptor. Two consequences, and they pull opposite
       ways:

       Good: nothing allocates here, so the charter's "no allocation on
       the hot path" holds by construction rather than by care.

       Open: we are installing a bare 68K pointer where a native PowerPC
       caller may need a descriptor to reach us. The toolchain will not
       build one for us on this target, so if the ladder says PPC
       QuickDraw cannot call this, the fix is a hand-built M68K routine
       descriptor plus an RTS thunk - the shape that unfroze the `cis`
       verb. That is the probe's question, now with a known answer for
       what to try next if it comes back no. */
    e->procs.rectProc = NewQDRectUPP(qdprobe_rect);
    e->port = (unsigned long)cp;
    e->saved_procs = (unsigned long)cp->grafProcs;
    e->a5 = (unsigned long)LMGetCurrentA5();
    /* Published last: until grafProcs points at us, nothing can call our
       proc, and our entry must be complete before it can. */
    cp->grafProcs = &e->procs;
    ++gPortCount;
    ++gShared->patches;
    gShared->armed_ports = (unsigned long)gPortCount;
}

/* Un-patch every port we patched FROM THIS CONTEXT. The A5 gate is the
   whole safety story: a port lives in its application's heap, and when
   that application quits the heap is gone. Reaching into it to tidy up
   would be a write through freed memory in a process that no longer
   exists. So an entry belonging to another context is left alone here
   and cleaned up when we are next running in that context - or never,
   if the app quit, which is a leaked table row and is the cheap failure.

   The second gate is verification: if the port's grafProcs is no longer
   ours, someone patched over us or the memory was reused. Unwinding a
   chain we are not on top of corrupts whoever is. Count it and stop. */
static void restore_ports(void)
{
    unsigned long a5 = (unsigned long)LMGetCurrentA5();
    short i;
    short kept = 0;

    for (i = 0; i < gPortCount; ++i) {
        QDProbePort *e = &gPorts[i];
        CGrafPtr cp = (CGrafPtr)e->port;

        if (e->a5 != a5) {
            gPorts[kept++] = *e;      /* not our context; leave it */
            continue;
        }
        if (cp->grafProcs != &e->procs) {
            ++gShared->stranded;      /* someone else is on top */
            continue;
        }
        cp->grafProcs = (CQDProcs *)e->saved_procs;
        ++gShared->restores;
    }
    gPortCount = kept;
    gShared->armed_ports = (unsigned long)gPortCount;
}

/* Called from the shim on every GetNextEvent/WaitNextEvent, in whatever
   process is pumping - the same position NOW's core uses, and the only
   moment a foreign process's port is legitimately current. */
void qdprobe_gne_apply(void)
{
    if (gShared == NULL) {
        return;
    }
    gShared->heartbeat = (unsigned long)LMGetTicks();
    if (gShared->arm != 0) {
        patch_current_port();
    } else if (gPortCount > 0) {
        restore_ports();
    }
}

static pascal OSErr qdprobe_gestalt(OSType selector, long *response)
{
    (void)selector;
    *response = (long)gShared;
    return noErr;
}

void _start(void)
{
    Handle self;
    SelectorFunctionUPP gestalt_upp;
    QDProbeShared *shared;

    RETRO68_RELOCATE();
    Retro68CallConstructors();

    self = Get1Resource('INIT', 128);
    if (self == NULL) {
        return;
    }
    DetachResource(self);

    shared = (QDProbeShared *)NewPtrSysClear((Size)sizeof(QDProbeShared));
    if (shared == NULL) {
        return;
    }
    shared->magic = (unsigned long)kQDProbeMagic;
    shared->heartbeat = (unsigned long)LMGetTicks();
    /* Dark on arrival. An INIT that starts patching every port it sees
       at boot is a machine you cannot shift-boot out of fast enough. */
    shared->arm = 0;
    gShared = shared;

    gestalt_upp = NewSelectorFunctionUPP(qdprobe_gestalt);
    if (NewGestalt((OSType)kQDProbeGestalt, gestalt_upp) != noErr) {
        if (gestalt_upp != NULL) {
            DisposeSelectorFunctionUPP(gestalt_upp);
        }
        DisposePtr((Ptr)shared);
        gShared = NULL;
        return;
    }

    gQDProbeOldGNEFilter = LMGetGNEFilter();
    LMSetGNEFilter((GetNextEventFilterUPP)qdprobe_gne_filter);
}
