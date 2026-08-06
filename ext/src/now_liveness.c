/*
 * P6, the liveness vehicle - the extension's first INTERRUPT-time
 * context, and the half of the liveness plane that can be built today.
 * ------------------------------------------------------------------
 * WHY THIS EXISTS, measured rather than argued. On 2026-08-05 the Mirror
 * was driven into the Finder's "could not find the application program"
 * alert and the whole guest went silent for over ninety seconds - NOW
 * and `tbt-worker` alike, a background-only application on its own port
 * with no code in common. The host's silence window is ~75 s, so the
 * wire died against a perfectly healthy Macintosh, and one ordinary
 * dialog ended the session.
 *
 * Liveness was being answered BY THE APPLICATION, and a modal is exactly
 * what takes the application away.
 *
 * WHY THE EXTENSION NEEDED A NEW VEHICLE. Every execution context this
 * component already had is application-driven: `now_ext.c` installs a
 * jGNE filter, which runs when somebody calls GetNextEvent, and the act
 * plane's patches fire when somebody calls a trap. During the exact
 * starvation this addresses, NONE of them run. The Time Manager task
 * below is the first thing here that runs whether or not any application
 * is being scheduled, and its discipline is stricter than anything else
 * in this component: no allocation, no Toolbox that moves memory,
 * nothing that can block.
 *
 * WHAT IT DOES TODAY: proves it runs. `liveness_ticks` is bumped on
 * every tick and by nothing else, so an application can read it either
 * side of a starvation and say whether anything on this machine kept
 * running while no application did. Under `tools/guest-wedge spin` an
 * application-level probe stops answering; this counter must keep
 * climbing. That is the premise of the whole plane, made checkable.
 *
 * WHAT IT DOES NOT DO, AND WHY - THE FINDING THAT STOPPED IT.
 * The plan had this task dial the host itself over Open Transport, so a
 * starved machine could answer for itself. **It cannot, in this
 * component, and the reason is structural rather than a matter of
 * effort.** Linking OT's own client glue into the extension fails at
 * link time on `__SLM11FuncDispatch`, `__SLM11VTableDispatch`,
 * `__SLM11ConstructorDispatch`, `__SLM11ExtblDispatch` and
 * `__gOTClientRecord`: OT's 68K libraries are CFM/Shared Library Manager
 * fragments, and this extension is a FLAT 68K code resource
 * (`-Wl,--mac-flat`). The two linkage models do not meet. Tried against
 * four library combinations, including the application flavour; the
 * fewest unresolved symbols was fifteen.
 *
 * That is the metal question of plan 012 § C answered at link time
 * instead of on a PowerBook, which is much the cheaper place to find it.
 * The routes left are all design forks and none is a small edit: reach
 * TCP through the Device Manager instead (MacTCP's `.ipp` driver, which
 * a flat 68K INIT can drive with PBControl and completion routines, and
 * which OS 9's OT still provides for exactly these callers); or ship the
 * resident as a CFM fragment or an OT module rather than an INIT. That
 * choice is Michelle's and is recorded in docs/open-issues.md.
 *
 * So this file is the vehicle, honestly short of the journey - and the
 * vehicle is the part the premise depends on.
 */

#include <Devices.h>
#include <Gestalt.h>
#include <LowMem.h>
#include <MacTypes.h>
#include <Timer.h>

#include "peek_table.h"

/* The cadence. Stated HERE and nowhere else, and derived from the host's
   own window rather than chosen: the host declares a guest gone after
   ~75 s of silence and the contract has the application ping at 30 s, so
   a backstop ticking well inside 30 s can never be the reason a session
   lapses. It is deliberately NOT tuned to the 90 s starvation measured
   on 2026-08-05 - that is one observation of one alert, and a cadence
   derived from it would be a cadence derived from an accident. */
enum {
    kLivenessTickMs = 5000
};

/* Everything the task needs travels IN the task record.

   The Time Manager hands the task its own record back, so a tick needs
   no ambient state at all — which is the discipline an interrupt-time
   context wants regardless of whether it strictly needs it here.

   **2026-08-05, corrected: the reason first written here was wrong, and
   is left visible because it was a plausible wrong answer.** The first
   build's counter stopped at 1 and that was blamed on an arbitrary A5,
   on the theory that Retro68 addresses globals through A5. It does not,
   in THIS component: `_start` calls RETRO68_RELOCATE and never frees the
   globals, so the flat blob's statics live at fixed system-heap
   addresses. The proof is already in the tree — `now_ext_gne.S` reaches
   `gNowExtOldGNEFilter` with an absolute load, from inside every
   application's context, and the anchor plane's `gLastA5` fast path
   works across processes. Both would be luck if the A5 story held.

   The real defect was the callback ABI, and it is now in
   `now_liveness_tm.S`. */
typedef struct {
    TMTask task;                /* first: the Time Manager owns this */
    NowPeekTable *table;
    NowPeekU32 visible_epoch;   /* the epoch it would dial, if it could */
} LivenessTask;

static LivenessTask gLivenessTask;
static Boolean gTaskInstalled = false;
static Boolean gTransportProbed = false;
static short gTransportRefNum = 0;

/* The assembly shim (now_liveness_tm.S) the Time Manager actually calls. */
extern void now_liveness_tm_entry(void);

/* The channel (now_liveness_net.c). Its own translation unit for the
   reason the content plane is two: this file is the VEHICLE and its only
   claim is that it runs when nothing else does. Mixing the transport in
   would make a file that hangs a boot harder to disarm, and disarming it
   is the recovery procedure. */
extern void now_liveness_net_prepare(NowPeekTable *table, short refnum);
extern void now_liveness_net_pump(NowPeekTable *table,
                                  const NowPeekLivenessEndpoint *want);

/* What the application published, or nothing. Gated on length and on the
   format word beside it - the accretive rule every other plane follows,
   where an older application is SHORTER and says so by being shorter. */
static const NowPeekLivenessEndpoint *published_endpoint(NowPeekTable *table)
{
    if (table == NULL) return NULL;
    if (table->length < (NowPeekU32)(offsetof(NowPeekTable, endpoint)
                                     + sizeof(NowPeekLivenessEndpoint))) {
        return NULL;
    }
    /* V2 or later only. V1 named no OS string, and without one the host
       cannot fingerprint this channel onto its own application's session
       — a channel it cannot attach to anything is indistinguishable from
       no channel, so dialling on V1 would spend a connection to prove
       nothing. Nothing ever published V1; it is refused rather than
       supported so that a future V1 writer fails visibly. */
    if (table->endpoint_format < kNowPeekLivenessFormatV2) return NULL;
    if (table->length < (NowPeekU32)(offsetof(NowPeekTable, endpoint_os)
                                     + sizeof table->endpoint_os)) {
        return NULL;
    }
    /* Zero is an instruction to stay off the wire, not an old value worth
       retrying: an application that has never connected and one that has
       withdrawn consent must look the same here. */
    if (table->endpoint.endpoint_epoch == 0) return NULL;
    return &table->endpoint;
}

/* Called from the assembly shim (`now_liveness_tm.S`), which is what
   turns the Time Manager's register-based call into this ordinary C one.
   External linkage for that reason, and named for the component rather
   than the file so the symbol reads the same from assembly. */
void now_liveness_tick(TMTaskPtr task)
{
    /* **Nothing here may allocate, block, move memory, or call anything
       that could.** This is interrupt time: the Time Manager fires it
       whether or not any application is being scheduled — which is the
       entire reason it exists — and everything it needs comes through the
       record it is handed.

       The magic check is not defensive habit. If this pointer is ever
       wrong again, the failure mode is a five-second write into somebody
       else's memory during boot, which is precisely the shape that cost
       2026-08-05: a wrong pointer must cost a silent tick, not a machine.

       Re-primed at the end rather than the start, so a long tick can
       never overlap itself. */
    LivenessTask *self = (LivenessTask *)task;
    NowPeekTable *table;
    const NowPeekLivenessEndpoint *want;

    if (self == NULL) {
        return;                       /* nothing to re-prime, either */
    }
    table = self->table;
    if (table != NULL && table->magic == (NowPeekU32)kNowPeekTableMagic) {
        table->liveness_ticks++;
        want = published_endpoint(table);
        self->visible_epoch = (want != NULL) ? want->endpoint_epoch : 0;
        /* The journey. Everything it does is asynchronous or a memory
           read — see now_liveness_net.c's header for why there are no
           completion routines, which is the one design choice here worth
           arguing with. */
        now_liveness_net_pump(table, want);
    }
    PrimeTime((QElemPtr)task, kLivenessTickMs);
}

/* § 4's first question, and deliberately ONLY the first one: can this
   component reach a transport at all?

   **Why this is a probe and not a dial.** The previous transport attempt
   was killed by the linker after four library combinations, which was
   much the cheapest place to find it. MacTCP's `.ipp` driver is the route
   that survives that argument — the Device Manager is traps, so `PBOpen`
   needs no library and a flat 68K code resource can call it — but
   "survives an argument" is not a status this project accepts. So: open
   the driver, write down what it said, dial nothing. If a machine cannot
   even open it, the whole transport is dead for one boot's cost rather
   than for a transport's.

   **Why it runs HERE and not in the tick.** Two reasons, and either alone
   would settle it. `PBOpen` is a synchronous Device Manager call that can
   move memory and block, which is exactly what an interrupt-time context
   may never do. And MacTCP is not loaded at INIT time, so asking at
   `_start` would answer a question about boot ordering rather than about
   the machine. The jGNE filter's first pass is after boot, in an
   application's context, at non-interrupt time — the one place in this
   component where a call like this is legal.

   Once only, whatever the answer. A driver that refused is not retried
   on every event-loop pass: that would be a synchronous Toolbox call in
   the hot path of every application on the machine, which is the shape of
   defect this component exists to avoid. */
void now_liveness_probe_transport(NowPeekTable *table)
{
    ParamBlockRec pb;
    OSErr err;
    /* The driver name is a Pascal string and is built as bytes rather
       than written as "\p.IPP": this file compiles under -Wall -Wextra
       -Werror and a Pascal string literal is a dialect the host cc that
       reads this contract does not share. */
    static const unsigned char kIPPName[5] = { 4, '.', 'I', 'P', 'P' };

    if (gTransportProbed || table == NULL) return;
    gTransportProbed = true;             /* once, whatever it answers */

    table->transport_format = kNowPeekTransportFormatV1;

    pb.ioParam.ioCompletion = NULL;
    pb.ioParam.ioNamePtr = (StringPtr)kIPPName;
    pb.ioParam.ioVRefNum = 0;
    pb.ioParam.ioPermssn = fsCurPerm;
    err = PBOpenSync(&pb);
    /* Committed LAST, like every other publish in this table: a reader
       that sees a probe state has the result that goes with it. */
    table->transport_result = (NowPeekI32)err;
    if (err == noErr) {
        gTransportRefNum = pb.ioParam.ioRefNum;
        table->transport_probe = kNowPeekTransportOpen;
    } else {
        table->transport_probe = kNowPeekTransportRefused;
    }
    /* And, in the same one-shot non-interrupt pass, the only other thing
       this component ever does that could move memory: creating the TCP
       stream. It is here rather than in the tick for exactly the reason
       the open above is. A refused driver hands it 0 and it records a
       machine with no transport rather than trying anyway. */
    now_liveness_net_prepare(table, (err == noErr) ? gTransportRefNum : 0);
    /* The channel's own capability bit, and it is a SECOND bit rather
       than a widening of the vehicle's: capabilities are bits and are
       never inferred from a version, so "there is a resident here that
       ticks" and "there is one that can speak" stay separately
       answerable. Set only when a stream actually exists. */
    if (table->channel_state != kNowPeekChannelNoTransport) {
        table->caps |= kNowPeekTableCapLivenessNet;
    }
}

/* Installed LAST by now_ext.c, after everything else is in place, per
   the INIT failure-atomicity rule that file states: a callback able to
   fire must not be able to find a half-built world. */
void now_liveness_install(NowPeekTable *table)
{
    if (gTaskInstalled || table == NULL) return;

    /* **RE-ARMED 2026-08-05**, after the boot hang that disarmed it was
       diagnosed from the headers rather than guessed at. It hung because
       `tmAddr` pointed straight at a C function, and a Time Manager task
       is called with its record in A1 — so the C function read a stack
       argument that belonged to whatever it interrupted, wrote the
       counter through it, and re-primed it. `now_liveness_tm.S` carries
       the finding and the entry point; the shim is the fix.

       The rule the disarm was made under still stands and is worth
       restating where it can be acted on: an extension that can hang a
       Macintosh at startup is the worst thing this component can be,
       recoverable only by pulling the file from a machine that will not
       boot. If this ever hangs a boot again, disarm it HERE (a `return`
       on this line) rather than reasoning about it on someone's image. */
    table->liveness_ticks = 0;
    gLivenessTask.table = table;
    gLivenessTask.visible_epoch = 0;
    /* Cast, not NewTimerProc. On classic 68K NewRoutineDescriptor is a
       no-op macro returning its ProcPtr, so the two are the same address
       — but writing the cast says out loud that this field holds bare
       68K code with a non-C ABI, which is the fact the shim exists for.
       Same shape, and same reason, as the jGNE install in now_ext.c. */
    gLivenessTask.task.tmAddr = (TimerUPP)now_liveness_tm_entry;
    gLivenessTask.task.tmWakeUp = 0;
    gLivenessTask.task.tmReserved = 0;
    InsTime((QElemPtr)&gLivenessTask.task);
    PrimeTime((QElemPtr)&gLivenessTask.task, kLivenessTickMs);
    gTaskInstalled = true;
    /* The capability bit says the VEHICLE is here, which is all it has
       ever claimed: capabilities are bits and never inferred from a
       version, so a later build that gains the transport says so with
       its own bit rather than by this one changing meaning. */
    table->caps |= kNowPeekTableCapLiveness;
}
