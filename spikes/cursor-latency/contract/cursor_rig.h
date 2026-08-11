/*
 * cursor_rig.h - the one contract of the cursor-latency spike.
 *
 * THIS IS A RIG, NOT A PRODUCT. It clicks at raw screen points with no
 * idea what is under them, it drives the pointer from an interrupt, and
 * it declares itself exclusive because two residents patching the same
 * machine is how a boot dies. Nothing here is a route to shipping; see
 * README.md.
 *
 * Three sides compile this file: the 68K INIT (the writer), the PowerPC
 * application (the intake), and the host `cc` that runs the native test
 * over the pure logic. That is the whole reason it is one file - two
 * compilers sharing a struct is where silent packing drift bites, so
 * every field is naturally aligned, in declaration order, and the sizes
 * are pinned below by static assertion.
 *
 * Wire byte order is big-endian, which is what both guests are; the
 * host packs explicitly rather than casting a struct over the socket.
 *
 * TIME IS TICKS. TickCount() is 1/60 s, it is a low-memory read rather
 * than a trap, and it is the only clock cheap enough to read from the
 * inside of an interrupt-level task. Nothing here converts to
 * milliseconds and neither should any report: a tick is honest and a
 * millisecond derived from one invents precision the clock never had.
 * The known limitation, stated rather than papered over: measuring a
 * ~1-tick process with a 1-tick clock aliases, so a genuinely tight
 * distribution can read as a bimodal 0/1 spread. Ticks resolve the tail,
 * which is what this spike is about, and mislead about the fine shape of
 * the good case.
 */

#ifndef CURSOR_RIG_H
#define CURSOR_RIG_H

/* Fixed-width types without <stdint.h>: the 68K Universal Interfaces
   world does not have it, and the host cc must agree with the guests
   exactly. `int` is 32 bits on all three (Retro68's 68K gcc, the
   PowerPC gcc, and host cc); `long` is NOT - it is 64 bits on the
   64-bit host, which the assertions at the bottom of this file caught
   the first time this header was compiled. */
typedef unsigned char  RigU8;
typedef unsigned short RigU16;
typedef short          RigI16;
typedef unsigned int   RigU32;
typedef int            RigI32;

/* ---------------------------------------------------------------- wire */

#define kRigWireMagic   0x43524731U    /* 'CRG1' */
#define kRigWireVersion 1

/* Host -> guest. One fixed-size datagram, because a cursor stream that
   needs framing has already lost. */
enum {
    kRigOpMove      = 1,    /* absolute position; the whole point */
    kRigOpClick     = 2,    /* arg: 0 = up, 1 = down (raw point, see above) */
    kRigOpBeginRun  = 3,    /* arg: intake mode; clears the ring and counters */
    kRigOpEndRun    = 4,
    kRigOpDump      = 5,    /* arg: first sample index wanted */
    kRigOpPing      = 6,    /* echoed at intake time; the wire-only run */
    kRigOpQuit      = 7,    /* the rig application quits (automation) */
    kRigOpLoad      = 8     /* arg: profile; h: duration in ticks */
};

/* What the load generator does to the machine. The idle baseline is a
   COMPARISON and never the headline: a cursor rig that only ever runs
   against an idle Finder measures the one condition under which the
   defect cannot appear. */
enum {
    kRigLoadIdle     = 0,
    kRigLoadSpin     = 1,   /* a busy loop that never yields: pure
                               cooperative starvation, the floor case */
    kRigLoadTracking = 2,   /* the DragGrayRgn shape - StillDown/GetMouse
                               round a tight loop, which is what actually
                               happens while a person drags something */
    kRigLoadDrawing  = 3,   /* QuickDraw churn: competes for the screen,
                               not just the processor */
    kRigLoadPolite   = 4    /* heavy work that DOES reach WaitNextEvent,
                               so the picture debt can still settle */
};

/* Who applies the position, and it is a measurement A/B rather than a
   preference. kRigModeTimer is the design the spike set out to test (an
   interrupt-level Time Manager task, cadenced, coalescing); kRigModeIntake
   applies inside the intake itself the moment the packet lands. Running
   both answers whether the Time Manager task earns its place. */
enum {
    kRigModeTimer  = 0,
    kRigModeIntake = 1
};

typedef struct RigCommand {
    RigU32 magic;
    RigU16 version;
    RigU16 op;
    RigU32 seq;
    RigI16 h;
    RigI16 v;
    RigU16 arg;
    RigU16 pad;
    RigU32 host_stamp;      /* opaque to the guest; echoed back for pairing */
} RigCommand;

#define kRigCommandSize 24

/* ------------------------------------------------------------- samples */

/* One sample per command the intake saw. Arrival and apply are separate
   fields and that separation is the deliverable: "the wire was slow" and
   "we were not scheduled" have different fixes and identical symptoms.
   Redraw is the third, because a position nobody can see is not a
   pointer - the picture is settled at event-loop time and an application
   in a tracking loop may not reach one for a long while. */
typedef struct RigSample {
    RigU32 seq;
    RigU32 arrival_ticks;
    RigU32 apply_ticks;     /* 0 = never applied (coalesced away) */
    RigU32 redraw_ticks;    /* 0 = the picture was never settled for it */
    RigI16 h;
    RigI16 v;
    RigU16 flags;
    RigU16 coalesced;       /* commands this one overwrote before applying */
} RigSample;

#define kRigSampleSize 24

enum {
    kRigSampleApplied    = 0x0001,
    kRigSampleCoalesced  = 0x0002,  /* superseded before the writer ran */
    kRigSampleClick      = 0x0004,
    kRigSampleOutOfOrder = 0x0008,  /* seq older than one already applied */
    kRigSampleRedrawn    = 0x0010,
    kRigSampleIntakeApply= 0x0020   /* applied by the intake, not the timer */
};

/* 4096 samples is 96 KB in the system heap, preallocated at boot and
   never grown: allocation moves memory, and memory moving under an
   interrupt-level writer is the failure this rig would report as
   jitter. A 60-second run at 60 Hz is 3600 samples, so a normal run
   fits and an abnormal one overflows LOUDLY (dropped, below). */
#define kRigRingCap 4096

/* How far back the picture settlement looks for the sample it belongs
   to. Bounded because it runs inside somebody else's event loop; 8 is
   comfortably more than the number of samples that can be stamped
   between a write and the next event-loop pass at 60 Hz. */
#define kRigRedrawLookback 8

/* ---------------------------------------------------------------- table */

#define kRigTableMagic    0x43526754U  /* 'CRgT' */
#define kRigGestaltSelector 0x43526967L /* 'CRig' */
#define kRigTableFormat   1

/* The mailbox is one slot on purpose. Several positions arriving while
   the writer was not scheduled must collapse to the newest - a replayed
   backlog is exactly the wonky motion this spike exists to avoid. The
   ones discarded are counted, never silently dropped. */
typedef struct RigMailbox {
    RigU32 seq;
    RigU32 arrival_ticks;
    RigI16 h;
    RigI16 v;
    RigU16 op;
    RigU16 arg;
    RigU32 ring_index;      /* the sample this command wrote */
    RigU32 pending;         /* non-zero: the writer has not taken it yet */
} RigMailbox;

typedef struct RigTable {
    RigU32 magic;
    RigU32 format;
    RigU32 length;          /* bytes, this header + the ring */
    RigU32 caps;

    /* Which build is actually resident, and which is actually running.
       A stale extension is indistinguishable from a live one by every
       other field in this table - the file is in the folder, Gestalt
       answers, the magic is right - so the host demands these back and
       refuses to measure a build it did not stage. Written by the INIT
       and by the intake respectively (tools/gen_build_id.py). */
    RigU32 build_id;
    RigU32 app_build_id;

    /* Why the resident is not working, when it is not working. A rig
       that refuses to install and says nothing is indistinguishable
       from one that was never staged, and the two have completely
       different cures. So a refusal still publishes this table - with
       no capabilities and no hooks installed - purely so the host can
       be told which it is. */
    RigU32 refused;

    RigU32 armed;           /* a run is in progress */
    RigU32 mode;            /* kRigModeTimer | kRigModeIntake */
    RigU32 run_seed;        /* the host's seed, so a run can be replayed */
    RigU32 run_start_ticks;

    RigMailbox mailbox;

    /* Counters. Every one is a floor unless the drop counters are zero. */
    RigU32 received;        /* commands the intake stamped */
    RigU32 applied;         /* positions the writer wrote */
    RigU32 coalesced;       /* commands superseded before the writer ran */
    RigU32 out_of_order;    /* applied with a seq below the high-water mark */
    RigU32 ring_dropped;    /* samples the ring overwrote - see kRigRingCap */
    RigU32 timer_ticks;     /* Time Manager task firings, armed or not */
    RigU32 intake_calls;    /* intake entries (notifier or poll) */
    RigU32 app_passes;      /* application event-loop passes: the starvation
                               series, and the reason a stall is attributable */
    RigU32 redraws;         /* redraws ATTRIBUTED to a sample */
    RigU32 redraw_calls;    /* redraws actually performed - the two differ,
                               and the gap is the instrument's blind spot
                               rather than the machine's behaviour */
    RigU32 last_seq;        /* high-water mark of applied seq */
    RigU32 last_apply_ticks;
    RigU32 place_route;     /* how the last placement reached the machine */

    /* The load generator's channel, and it rides in the table rather
       than on a socket of its own for one reason: "while the guest is
       doing other things" is the condition under which the defect
       exists at all, so the thing that CREATES that condition must not
       add traffic to the wire being measured. The starver polls these
       fields from its own event loop; the intake writes them. */
    RigU32 load_seq;        /* bumped by the intake; the starver's trigger */
    RigU32 load_profile;
    RigU32 load_ticks;      /* how long to hold the machine */
    RigU32 load_running;    /* the starver sets and clears this itself */
    RigU32 load_started;
    RigU32 load_finished;

    RigU32 ring_head;       /* next index to write */
    RigU32 ring_cap;
    RigU32 ring_count;      /* total samples ever written */
    RigU32 gne_passes;      /* event-loop passes by ANY process: the series
                               that says whether the machine was pumping at
                               all, as distinct from the rig app being run */

    RigSample ring[kRigRingCap];
} RigTable;

/* Which route the picture took. A cursor plane that is present and
   silently taking the route that does not draw looks identical to one
   that works, so the route is recorded rather than assumed. */
enum {
    kRigRouteNone      = 0,
    kRigRouteLowMem    = 1,   /* MTemp/RawMouse/MouseLocation only */
    kRigRouteDevice    = 2,   /* + Cursor Device Manager */
    kRigRouteRedrawOwed= 3    /* + a redraw the event loop still owes */
};

/* Capability bits the INIT publishes, so the host can tell a rig that
   could not do something from one that chose not to. */
enum {
    kRigRefusedNone      = 0,
    kRigRefusedConflict  = 2,   /* another resident owns these traps */
    kRigRefusedNoHeap    = 3
};

enum {
    kRigCapTimer   = 0x0001,
    kRigCapDevice  = 0x0002,  /* _CursorDeviceDispatch answered with a device */
    kRigCapRedraw  = 0x0004,  /* a jGNE filter is chained to settle the picture */
    kRigCapTrackingPatch = 0x0008
        /* GetMouse/StillDown/Button are patched, so the picture can be
           settled INSIDE a tracking loop - the only task-time moment
           available while an application drags something and never
           reaches WaitNextEvent. Without this the position follows
           perfectly and the arrow does not move at all. */
};

/* ------------------------------------------------------------ retrieval */

/* The tail is stored on the guest and pulled AFTERWARDS. Measuring
   latency over the network while the measurement itself uses the
   network is a trap this lab has already paid for once - a polling
   probe refreshed the very timeout it was measuring. During a run the
   only traffic is the thing under test; a dump request is sent when the
   run is over, and is answered from the application's event loop rather
   than from the intake, so nothing on the measured path is involved
   even in principle.
   The counters ride on EVERY reply, so a dump that is cut short still
   carries the totals a partial sample list must be read against. */
#define kRigDumpMagic 0x43524744U   /* 'CRGD' */
#define kRigDumpChunk 24            /* samples per datagram: 664 bytes */

typedef struct RigDumpReply {
    RigU32 magic;
    RigU32 first;               /* ring index of samples[0] */
    RigU32 count;               /* samples in this datagram */
    RigU32 caps;

    RigU32 ring_count;
    RigU32 ring_head;
    RigU32 ring_cap;
    RigU32 ring_dropped;

    RigU32 received;
    RigU32 applied;
    RigU32 coalesced;
    RigU32 out_of_order;

    RigU32 timer_ticks;
    RigU32 intake_calls;
    RigU32 app_passes;
    RigU32 gne_passes;

    RigU32 redraws;
    RigU32 place_route;
    RigU32 run_seed;
    RigU32 run_start_ticks;
    RigU32 redraw_calls;
    RigU32 reserved1;
    RigU32 reserved2;
    RigU32 reserved3;

    RigU32 last_apply_ticks;
    RigU32 now_ticks;           /* when this reply was built */
    RigU32 armed;
    RigU32 mode;

    RigU32 build_id;            /* the resident's identity - see the table */
    RigU32 app_build_id;
    RigU32 load_profile;        /* what the starver was asked to do */
    RigU32 load_running;
    RigU32 refused;
    /* The load's own window, in guest ticks, so that "measured under
       load" can be PROVEN from the same dump as the measurement rather
       than assumed from the fact that a load was requested. The starver
       only notices a request when its event loop next runs, so a load
       can start late - and a check whose placements fell outside the
       window would be an idle measurement wearing a load's name. */
    RigU32 load_started;
    RigU32 load_ticks;

    RigSample samples[kRigDumpChunk];
} RigDumpReply;

/* --------------------------------------------------- shared decisions */

/* The two decisions worth testing on the host, where a test can watch
   them fail: which mailbox write wins, and where a sample lands in the
   ring. They are in cursor_rig_logic.c, compiled by all three sides. */

void rig_ring_reset(RigTable *t);

/* Stamp a command into the ring and the mailbox. Returns the ring index.
   Coalescing happens here: if the mailbox still holds an unapplied
   command, that one is marked superseded and counted. */
RigU32 rig_intake_stamp(RigTable *t, const RigCommand *cmd, RigU32 now_ticks);

/* Take the pending command, if any. Returns 0 when there is nothing to
   do - the writer must be able to fire on an empty mailbox forever
   without touching the machine. */
int rig_mailbox_take(RigTable *t, RigMailbox *out);

/* Record that a command was applied at now_ticks. Flags out-of-order
   application against the high-water mark rather than hiding it: a
   pointer that ever moves backwards relative to command order is
   unusable at any speed, and this is the field that says so. */
void rig_apply_record(RigTable *t, const RigMailbox *box, RigU32 now_ticks);

/* Settle the picture debt for the last applied sample. */
void rig_redraw_record(RigTable *t, RigU32 now_ticks);

/* Static assertions without <assert.h> or C11: a negative array bound is
   the portable way to fail a build on all three compilers. */
typedef char rig_assert_command_size[(sizeof(RigCommand) == kRigCommandSize) ? 1 : -1];
typedef char rig_assert_sample_size[(sizeof(RigSample) == kRigSampleSize) ? 1 : -1];
typedef char rig_assert_u32[(sizeof(RigU32) == 4) ? 1 : -1];
typedef char rig_assert_u16[(sizeof(RigU16) == 2) ? 1 : -1];

#endif /* CURSOR_RIG_H */
