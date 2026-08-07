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
 * WHERE THE JOURNEY WENT. This file is the VEHICLE and deliberately
 * stays only that; the channel it carries is `now_liveness_net.c`, its
 * own translation unit. The split is not tidiness - this file's recovery
 * procedure is "put a `return` at the top of now_liveness_install", and
 * a transport mixed in here would make the one thing that must stay easy
 * to switch off harder to find.
 *
 * The route was NOT the one the plan expected, and the reason is worth
 * keeping where somebody will read it before proposing it again.
 * **Open Transport is impossible from this component**, and the answer
 * came from the linker rather than from a machine: OT's 68K libraries
 * are CFM/Shared Library Manager fragments and this extension is a FLAT
 * 68K code resource (`-Wl,--mac-flat`), so they do not link
 * (`__SLM11FuncDispatch`, `__SLM11VTableDispatch`,
 * `__SLM11ConstructorDispatch`, `__SLM11ExtblDispatch`,
 * `__gOTClientRecord`; four library combinations, fifteen unresolved
 * symbols at best). That is plan 012 § C's metal question answered at
 * link time instead of on a PowerBook, much the cheaper place.
 *
 * MacTCP's `.IPP` driver is the route that survives, because the Device
 * Manager is TRAPS: `PBOpen` and `PBControl` need no library at all.
 */

#include <Devices.h>
#include <Gestalt.h>
#include <LowMem.h>
#include <MacTypes.h>
#include <Timer.h>

#include "peek_table.h"
#include "now_ext_core_logic.h"

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

/* Whether the task is currently priming itself.
 * ----------------------------------------------------------------------
 * THE STAND-DOWN, and the shape of it is the whole safety argument.
 *
 * The task is InsTime'd at boot and NEVER PrimeTime'd there, so a machine
 * whose application has never published an endpoint carries a queue entry
 * that never fires — no interrupt, no cost, nothing to remove.
 *
 * Starting it is a bare `PrimeTime` from the jGNE filter. Stopping it is
 * the tick DECLINING TO RE-PRIME. Nothing ever calls RmvTime, and that is
 * deliberate rather than timid: this task re-primes itself at the end of
 * every tick, so an RmvTime from the filter could land between a tick's
 * body and its own PrimeTime and re-arm a task that had just been pulled
 * out of the queue. Letting the task retire itself means only ONE context
 * — the tick — ever touches the Time Manager queue after install, so the
 * race cannot be constructed.
 *
 * That asymmetry is worth naming because it is the opposite of the act
 * plane's. A trap patch cannot be withdrawn at all once another extension
 * may have chained behind it, so P4 settles for a patch that returns
 * immediately. A Time Manager task has no such chain: nothing is queued
 * behind ours, so declining to re-prime genuinely stops it. P6 can do
 * what P4 cannot, and this flag is where the difference is spent.
 *
 * Written by both contexts, which is safe in both directions: a lost
 * "start" is retried on the filter's next pass, and a double PrimeTime
 * merely reschedules. */
static Boolean gTaskPriming = false;

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
    if (table == NULL || table->magic != (NowPeekU32)kNowPeekTableMagic) {
        /* A wrong pointer costs a silent tick, never a machine — and it
           costs no further ticks either, because a task that cannot read
           its own table can no longer decide whether it should run. */
        return;
    }
    table->liveness_ticks++;
    want = published_endpoint(table);
    self->visible_epoch = (want != NULL) ? want->endpoint_epoch : 0;
    /* The journey. Everything it does is asynchronous or a memory
       read — see now_liveness_net.c's header for why there are no
       completion routines, which is the one design choice here worth
       arguing with. */
    now_liveness_net_pump(table, want);
    /* THE STAND-DOWN, and it is the last thing the tick does.
       ------------------------------------------------------------------
       Re-priming is a decision, not a reflex. `LMGetTicks` is an address
       constant, not a trap, so reading the clock at interrupt time is a
       load; and the decision itself is a handful of comparisons in a file
       with no Toolbox in it. Both are legal here, which is what makes the
       retirement free.

       Declining to re-prime is how this task STOPS. Nothing removes it
       from the queue — see gTaskPriming for why that is the safe
       direction and not the lazy one — so the entry stays and a later
       PrimeTime from the filter starts it again. */
    if (now_ext_liveness_should_run(table, (NowPeekU32)LMGetTicks())) {
        PrimeTime((QElemPtr)task, kLivenessTickMs);
    } else {
        gTaskPriming = false;
        table->rest_state &= (NowPeekU16)~kNowPeekRestLivenessTicking;
    }
}

/* Start the vehicle if it should be running and is not.
 *
 * Called from the jGNE filter — non-interrupt time, in whatever process
 * is pumping — which is the same context the transport probe below needs
 * and for the same reason. A bare PrimeTime on an entry InsTime'd at boot
 * is the whole operation; there is no queue mutation and nothing to
 * unwind. */
static void liveness_prime_if_wanted(NowPeekTable *table, NowPeekU32 ticks)
{
    if (!gTaskInstalled || gTaskPriming) {
        return;
    }
    if (!now_ext_liveness_should_run(table, ticks)) {
        return;
    }
    gTaskPriming = true;
    table->rest_state |= (NowPeekU16)kNowPeekRestLivenessTicking;
    PrimeTime((QElemPtr)&gLivenessTask.task, kLivenessTickMs);
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

    if (table == NULL) return;
    /* NOTHING HAPPENS UNTIL AN APPLICATION ASKS, and this line is the
       landing blocker's actual fix.
       ------------------------------------------------------------------
       Before it, this routine ran on the first event-loop pass of every
       boot: any Macintosh carrying this extension opened MacTCP's .IPP
       driver and created a TCP stream with a receive buffer, whether or
       not NOW was ever launched. Nothing dialled — `published_endpoint`
       already gated that correctly — but the driver was open and the
       stream existed, which is a shared system resource held by a
       component nobody had asked for anything.

       The charter's promise is that a resident component is optional and
       the product degrades honestly without it. A machine whose user
       never runs NOW must therefore be indistinguishable from a machine
       without the extension, and holding a MacTCP stream is a visible
       difference. So: the same signal that permits dialling now permits
       reaching for the transport at all.

       This keeps the two properties the routine was built around. It is
       still once in the life of the machine, and it still runs at
       non-interrupt time in an application's context — the filter's pass
       after an endpoint appears is as good a pass as the filter's first,
       and is the only kind of context this component has. */
    if (!now_ext_liveness_should_run(table, (NowPeekU32)LMGetTicks())) {
        return;
    }
    /* The vehicle and the channel start together, from the same signal
       and in the same non-interrupt context. Priming first is deliberate:
       the tick is what keeps a session alive, and it should not be
       waiting on a driver that may refuse. */
    liveness_prime_if_wanted(table, (NowPeekU32)LMGetTicks());
    if (gTransportProbed) {
        /* The PROBE is once, whatever it answers. Creating the stream is
           not, and the difference is which question each asks: whether
           this machine has the driver at all cannot change during a boot,
           whereas whether the stack is ready to hand out a stream can and
           does - the first pass through here is somewhere in the booting
           Finder. now_liveness_net_prepare() returns immediately once it
           has succeeded or spent its small allowance. */
        now_liveness_net_prepare(table, gTransportRefNum);
        return;
    }
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
    /* What this machine is now HOLDING, as distinct from what it can do.
       The driver open and the stream are the durable half of this plane —
       neither is given back — so they are reported rather than left to be
       inferred from a capability bit that would have been set anyway. */
    if (table->transport_probe == kNowPeekTransportOpen) {
        table->rest_state |= (NowPeekU16)kNowPeekRestTransport;
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
    /* INSTALLED, AND DELIBERATELY NOT PRIMED.
       ------------------------------------------------------------------
       InsTime puts the entry in the Time Manager's queue; PrimeTime is
       what schedules it. Separating them here is the other half of the
       stand-down: on a machine whose application never publishes an
       endpoint this task is queued and never fires once, so the cost of
       carrying it is a QElem and no interrupts at all.

       It also makes the boot cheaper in the way that matters most for a
       file with this one's history. The riskiest moment this component
       has is a callback firing into a half-built world during startup;
       previously the first tick could arrive five seconds into the boot,
       and now the earliest it can arrive is five seconds after an
       application has published an endpoint, which is long after boot by
       construction. The recovery procedure is unchanged and still the
       first thing to reach for: a `return` at the top of this function. */
    InsTime((QElemPtr)&gLivenessTask.task);
    gTaskInstalled = true;
    /* Both capability bits, at boot, because both are facts about this
       BINARY: it has a vehicle, and it has code that can reach MacTCP and
       dial. Neither says anything is running — the vehicle is not even
       primed at this point, and no transport has been touched.

       The channel bit moved here on 2026-08-07 from the transport probe,
       where it was set only once a stream existed. That made it a state
       word with a capability's name, and it survived only because the
       probe used to run unconditionally at boot. See its comment in
       contract/peek_table.h: what is RUNNING is `channel_state`, what is
       HELD is `rest_state`, and this is what the binary CAN do. */
    table->caps |= kNowPeekTableCapLiveness | kNowPeekTableCapLivenessNet;
}
