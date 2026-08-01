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
 *
 * Arming is IDENTITY-SCOPED: a request names the A5 world it wants
 * instrumented, and a pass in any other context patches nothing. That is
 * not caution, it is a measured lesson from the sibling Portal INIT
 * (mirror, d9db2c4, docs/PORTAL-PLAN.md): a guard that bounds a patch's
 * COUNT or DURATION does not bound its SCOPE. Its MenuSelect patch was
 * single-flight and self-disarming, and still answered whichever call
 * arrived first - a real user press on an unrelated menu ran the armed
 * command 18/20. The sibling patch that additionally required the request
 * to name its exact ControlHandle hijacked 0/20. Same shape here, in the
 * observer case rather than the actuator case: without an identity check
 * we instrument whichever process happens to pump next, which is a
 * process nobody asked us to instrument.
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

    /* Layout version, EXACT match required of any reader. 1 was the
       pre-identity block; 2 added arm_a5 / arm_expiry and the refusal
       counters.

       This exists because of a defect the sibling Portal INIT shipped and
       then fixed (mirror, 739c42b, 2026-07-31). Its resident block gained
       a guard field, and a stale INIT still sitting in Extensions had no
       such field - so arming it left the guard OFF while the caller
       believed it ON. Their fix was PT_VERSION 1 -> 2 with the verb
       refusing anything older: "a stale extension is now a reboot instead
       of an unguarded patch nobody can see."

       It is the same defect here, and worse-shaped. A version-2 reader
       writing arm_a5 into a version-1 block writes into armed_ports, and
       arm_expiry into rect_calls, and then sets arm - at which point a
       version-1 probe sees a bare arm and patches EVERY port it meets,
       which is precisely the unscoped behaviour version 2 exists to
       remove. Silently, while the reader believes it named one target.

       An INIT makes this the LIKELY state rather than an unlucky one:
       the probe is installed by hand and loads at boot only, so "rebuilt
       the reader, forgot to cold-boot" is the ordinary iteration
       accident, not a rare one. */
    kQDProbeVersion = 2,

    /* Ports patched at once. Small on purpose: this is a spike, and a
       bigger table would only mean more to unwind if it goes wrong.
       Bounded by identity too - all 8 belong to one A5 world. */
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
   and one writer per field - the same discipline as NOW's table,
   INCLUDING its versioning. That was left out at first on the grounds
   that nothing ships this, which confused "throwaway" with "unversioned"
   and was wrong the moment the block started carrying a guard rather
   than only counters (see kQDProbeVersion).

   The request fields (arm / arm_a5 / arm_expiry) are the READER's, with
   one exception stated below, and `arm` is their commit word:

     to arm    write arm_a5 and arm_expiry FIRST, then arm LAST;
     to disarm write arm FIRST.

   A jGNE pass can land between any two of those stores, so the order is
   what keeps a live `arm` from ever being paired with a target from the
   previous request. The one field the resident code writes back is
   `arm`, and only to zero it when the deadline passes - a dead-man's
   switch whose whole point is that the reader may be gone.

   The target is keyed by A5 because that is what both sides can actually
   hold: LMGetCurrentA5() is a single low-memory read from resident code
   in any context, needs no Process Manager call and nothing that moves
   memory, and NOW's anchor plane already keys per-process state the same
   way (contract/peek_table.h), so a reader that has an anchor already
   has the value to write here. Two limits, stated where a reader will
   trip over them:

   - A5 names an A5 WORLD, not a process, and the value can be reused
     after an application quits. Re-arm per launch; the expiry is what
     bounds the window in which a recycled A5 could be mistaken for the
     target, which is the honest reason to keep a deadline even though
     it guards nothing about scope.
   - A background target never arms at all. Our hook only runs when the
     target runs, and a suspended process does not pump its event loop -
     upstream measured exactly this and got 6/6 timeouts trying to arm a
     backgrounded application (mirror, docs/STATUS.md). Identity-scoped
     arming can therefore only ever reach a target that is alive and
     pumping, which is a real bound on what this probe can observe, not
     a bug to be fixed here. */
typedef struct {
    unsigned long magic;
    /* Immediately after magic, and checked with it: a reader that
       matches the magic and ignores this has verified only that it found
       a QD Probe, not that it found one whose block it understands. See
       kQDProbeVersion - the two are one check, not two. */
    unsigned long version;
    unsigned long heartbeat;      /* TickCount at last jGNE pass */
    unsigned long arm;            /* READER (commit): nonzero = patch */
    unsigned long arm_a5;         /* READER: the ONLY A5 world we patch */
    unsigned long arm_expiry;     /* READER: TickCount after which arm lapses */
    unsigned long armed_ports;    /* entries currently patched */
    unsigned long rect_calls;     /* THE ANSWER: calls through our proc */
    unsigned long patches;        /* successful installs */
    unsigned long restores;       /* successful removals */
    unsigned long skipped;        /* ports we declined to patch */
    unsigned long stranded;       /* entries we refused to restore */
    /* Refusals, as passes rather than as distinct processes - these
       climb once per event-loop pass while a bad request stands, which
       is exactly what makes a misaddressed request visible. */
    unsigned long unscoped;       /* armed with no target named: refused */
    unsigned long foreign;        /* armed, but this is not the target */
    unsigned long expiries;       /* requests the dead-man's switch retired */
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

/* Patch the current port, if it is one we can safely patch. Called ONLY
   after the caller has established that `a5` is the armed target - the
   identity check does not live here, so that there is exactly one place
   in this file that decides whose ports we may touch. */
static void patch_current_port(unsigned long a5)
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
    /* The caller's A5, which the identity gate has already matched against
       the request. Recording it here is what lets restore_ports() refuse
       to touch this port from any other context. */
    e->a5 = a5;
    /* Published last: until grafProcs points at us, nothing can call our
       proc, and our entry must be complete before it can. */
    cp->grafProcs = &e->procs;
    ++gPortCount;
    ++gShared->patches;
    gShared->armed_ports = (unsigned long)gPortCount;
}

/* Un-patch every port we patched FROM THIS CONTEXT. Every entry now
   belongs to one armed target by construction, so in the common case
   this loop either restores all of them or none - but the gate is per
   entry regardless, because a request can be re-armed at a different
   target while an old entry is still stranded.

   The A5 gate is the whole safety story: a port lives in its application's heap, and when
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

/* Has the standing request outlived its deadline? Compared as a SIGNED
   difference so a TickCount wrap (~2 years of uptime) reads as "not yet"
   rather than "expired forever". A request with no deadline is expired on
   sight: same fail-closed rule as a request with no target. */
static Boolean request_expired(void)
{
    unsigned long now = (unsigned long)LMGetTicks();

    if (gShared->arm_expiry == 0) {
        return true;
    }
    return (long)(now - gShared->arm_expiry) >= 0;
}

/* Called from the shim on every GetNextEvent/WaitNextEvent, in whatever
   process is pumping - the same position NOW's core uses, and the only
   moment a foreign process's port is legitimately current.

   "Whatever process is pumping" is the hazard this function exists to
   contain. Being here says nothing about whether anyone asked for this
   process to be instrumented, so every path below is a refusal except
   the one where the caller IS the named target. */
void qdprobe_gne_apply(void)
{
    unsigned long a5;

    if (gShared == NULL) {
        return;
    }
    gShared->heartbeat = (unsigned long)LMGetTicks();

    /* Dead-man's switch, first, so an expired request cannot be acted on
       even once more. It bounds a request's DURATION, not its scope -
       the identity gate below is the only thing that bounds scope, and
       nothing here may be read as a substitute for it. Its one real
       virtue is independence: it fires in whatever process pumps next,
       so retiring a request does not need the target, or the reader,
       to still be alive. Upstream measured the absence of this: the
       Portal's guest never aged a request out, so an agent that died
       mid-verb left a patch armed indefinitely. */
    if (gShared->arm != 0 && request_expired()) {
        gShared->arm = 0;
        ++gShared->expiries;
    }

    if (gShared->arm != 0) {
        a5 = (unsigned long)LMGetCurrentA5();
        if (gShared->arm_a5 == 0) {
            /* Armed at nobody. This is the whole defect in one branch:
               the obvious reading of a bare `arm` is "instrument
               everything", and the fail-closed reading is "instrument
               nothing". A request that does not say whose ports it wants
               has not asked for anything we are willing to do. */
            ++gShared->unscoped;
        } else if (a5 != gShared->arm_a5) {
            ++gShared->foreign;       /* somebody else's event loop */
        } else {
            patch_current_port(a5);
        }
    } else if (gPortCount > 0) {
        /* Disarmed. Note the asymmetry, and it is not fixable from here:
           the refusals above take effect in every process immediately,
           because they are decided by whoever pumps. Un-patching is not -
           a port can only be restored from the context that patched it,
           so a disarm reaches the target's ports only when the target
           next pumps events. Disarm stops us instrumenting anything new;
           it does not promise the instrumentation is already gone. */
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
    shared->version = (unsigned long)kQDProbeVersion;
    shared->heartbeat = (unsigned long)LMGetTicks();
    /* Dark on arrival, and unaddressed on arrival. An INIT that starts
       patching every port it sees at boot is a machine you cannot
       shift-boot out of fast enough; NewPtrSysClear has already zeroed
       these, and they are restated because the zero VALUE is the safe
       one in all three cases - not armed, no target, already expired. */
    shared->arm = 0;
    shared->arm_a5 = 0;
    shared->arm_expiry = 0;
    /* Magic LAST, so a reader that somehow reaches this address early
       finds a block only once it is fully formed - and in particular
       only once `version` is set, since a zero version read beside a
       good magic is exactly the mismatch the version exists to catch.
       now_ext.c publishes its table the same way and for the same
       reason; this file had it backwards until 2026-07-31. */
    shared->magic = (unsigned long)kQDProbeMagic;
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
