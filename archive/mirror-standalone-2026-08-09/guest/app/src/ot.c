/*
 * ot.c - asynchronous Open Transport transport for the harness. See ot.h and
 * docs/09-async-transport.md.
 *
 * The notifier (deferred-task time) runs the OT state machine: accept the
 * connection onto the worker, drain OTRcv into gRbuf, drive OTSnd, and reset on
 * disconnect. The main loop (ot_idle) extracts a complete request line, runs the
 * handler (Toolbox-legal there, not in the notifier), and kicks the send.
 *
 * Buffers are file-scope statics: single connection served serially, so one set
 * is safe - and the notifier needs pre-allocated storage (no allocation at
 * deferred-task time). This also keeps the big buffers off the stack.
 */
#include "ot.h"

#include <string.h>
#include <stdio.h>
#include <Events.h>          /* TickCount - send-path timing probe */
#include <Timer.h>           /* Microseconds - nonblocking sub-tick send gate */

#ifdef TBT_CONTROL_HTTP
#include "control_frame.h"
#endif

#define kRcvBuf    16384    /* holds one whole `put` line (b64 of the largest
                               tunable chunk + envelope) before dispatch — and
                               headroom for pipelined follow-up lines */
#define kRespBuf   40960    /* headroom for a PackBits'd screenshot frame */

/* Notifier contextPtr tags: which endpoint fired. */
#define kTagListener  ((void *)1L)
#define kTagWorker    ((void *)2L)

/* Connection state (see docs/09). */
enum { kStIdle = 0, kStRecv, kStSending };

/*
 * A5 shim for a future 68K build (docs/09): async callbacks reach globals via
 * A5, which can be wrong when the notifier fires. No-op on PowerPC (CFM restores
 * RTOC per call). The 68K path is written but UNTESTED - we build PPC today.
 */
#if TARGET_CPU_68K
#include <OSUtils.h>
static long gA5;
#define OT_ENTER_A5()  long _olda5 = SetA5(gA5)
#define OT_LEAVE_A5()  ((void)SetA5(_olda5))
#define OT_CAPTURE_A5() (gA5 = SetCurrentA5())
#else
#define OT_ENTER_A5()  ((void)0)
#define OT_LEAVE_A5()  ((void)0)
#define OT_CAPTURE_A5() ((void)0)
#endif

static EndpointRef gListener = NULL;
static EndpointRef gWorker   = NULL;
static OTNotifyUPP gNotifyUPP = NULL;
static OTReqHandler gHandler = NULL;
static OTLogProc    gLog     = NULL;

static volatile int        gState = kStIdle;
static char                gRbuf[kRcvBuf];
static volatile OTByteCount gRlen = 0;
static char                gLine[kRcvBuf];   /* extracted request line (main loop) */
static char                gResp[kRespBuf];
static OTByteCount         gRespLen = 0;
static volatile OTByteCount gSent = 0;
static OTConfig            gOTConfig = { 0, 0, 0, 0, 1 };
static OTSchedState        gSendSchedule;

/* Accept scaffolding, filled in the notifier. */
static InetAddress gPeer;
static TCall       gCall;

/* Lossy event trace: the notifier writes ints (deferred-task-safe); ot_idle
 * drains and logs them from the main loop. */
static volatile OTEventCode gTraceCode[32];
static volatile OTResult    gTraceRes[32];
static volatile int         gTraceW = 0;
static int                  gTraceR = 0;

/* Send-path timing probe (metal large-response slowness, 2026-07-05). The
 * notifier only bumps counters and reads TickCount (both deferred-task-safe);
 * ot_idle logs the summary from the main loop when gSendDone flips. Answers
 * "is the 20 s in OUR OTSnd/flow-control loop, or below us in OT/the driver?" -
 * few calls + ~0 ticks => the wire/driver is slow (shrink the payload); many
 * flow stalls + big ticks => our chunking (fix the send loop). */
static volatile unsigned long gSendStart = 0;
static volatile unsigned long gSendEnd   = 0;
static volatile long          gSendCalls = 0;
static volatile long          gSendFlow  = 0;
static volatile unsigned long gSendBytes = 0;
static volatile int           gSendDone  = 0;

/* Low-distortion cumulative seam counters. The notifier performs only integer
 * increments; formatting and persistence remain on the main loop/host. */
static volatile unsigned long gStatRcvCalls = 0;
static volatile unsigned long gStatRcvBytes = 0;
static volatile unsigned long gStatRcvHighWater = 0;
static volatile unsigned long gStatSndCalls = 0;
static volatile unsigned long gStatSndBytes = 0;
static volatile unsigned long gStatSndFlow = 0;
static volatile unsigned long gStatSndContributions = 0;
static volatile unsigned long gStatPaceArms = 0;
static volatile unsigned long gStatPaceFires = 0;
static volatile unsigned long gStatPaceDeferred = 0;
static volatile unsigned long gStatLinesDrained = 0;
static volatile unsigned long gStatLinesDispatched = 0;
static unsigned long          gStatDispatchTicks = 0;
static unsigned long          gStatSleepHot = 0;
static unsigned long          gStatSleepCold = 0;

static unsigned long long ot_now_us(void)
{
    UnsignedWide now;

    Microseconds(&now);
    return ((unsigned long long)now.hi << 32) | now.lo;
}

/* Adaptive poll (docs/18 "poll sleep dominates the round-trip"): TickCount of
 * the last main-loop-visible wire activity (line dispatched / send finished).
 * ot_sleep_ticks keeps the WaitNextEvent sleep at 0 for kActiveWindow after it,
 * so back-to-back transfer round-trips never pay the idle sleep. */
#define kActiveWindow 60UL           /* ticks (~1 s) of hot polling after activity */
static unsigned long gLastActive = 0;

/* Listener watchdog (docs/09, correction 3): a connection indication that sits
 * in T_INCON past this grace window was leaked by the notifier handshake — the
 * normal T_LISTEN -> accept/refuse path resolves in milliseconds. ot_idle then
 * re-pulls it, which is what turns any indication leak we failed to imagine
 * into a logged recovery instead of permanent deafness. */
#define kInconGraceTicks 120UL       /* ~2 s */
static unsigned long gInconSince = 0;
static volatile long gAbortedIndications = 0;   /* notifier count; logged by ot_idle */
static long          gAbortedLogged = 0;

/* Connection watchdog (PB1400c wedges, 2026-07-14), two tiers:
 *
 * 1. A client that gets accepted and never sends a byte parks the single
 *    worker in kStRecv, and the listener then refuses every later
 *    connection — permanent deafness with the T_LISTEN/T_DISCONNECTCOMPLETE
 *    pair repeating in the log. Modern HTTP stacks open spare connections
 *    that behave exactly like this. Drop a connection still byteless past
 *    the short grace window.
 *
 * 2. A connection holding an INCOMPLETE buffered frame whose peer vanished
 *    (a close lost on the wire — routine on the Farallon link, which drops
 *    frames under burst) can never complete, and neither a byteless nor an
 *    empty-buffer rule sees it. A legitimate client finishes writing a
 *    request within a beat, so a partial frame with no receive progress past
 *    a short window is a corpse.
 *
 * 3. A connection that DID carry traffic but whose peer vanished without a
 *    close the guest observed (leaked ORDREL/DISCONNECT — seen live the same
 *    day: the slot stayed held after every client process was gone) parks
 *    the worker just as permanently. Drop any held connection that has been
 *    wire-quiet past the long window. Legacy persistent clients idling
 *    longer simply reconnect; a busy verb handler cannot be reaped because a
 *    blocking dispatch also blocks ot_idle. */
#define kSilentConnTicks  600UL      /* ~10 s from accept to first byte */
#define kStalledFrameTicks 900UL     /* ~15 s parked on a partial frame */
#define kIdleConnTicks    10800UL    /* ~3 min of wire silence on a held conn */
static volatile int  gConnFresh = 0;    /* set at T_PASSCON; ot_idle stamps */
static volatile int  gConnSawData = 0;  /* any OTRcv progress this connection */
static unsigned long gConnSince = 0;    /* main-loop TickCount of the accept */

/* Catch-all servability check: the tiers above reap the failure shapes we
 * have enumerated, but metal keeps finding new ones (a release that half
 * completes leaves the endpoint diverged from the gState bookkeeping, where
 * no tier runs). If the worker cannot accept AND nothing has moved on the
 * wire for a sustained window, the transport is not serving — report that
 * through ot_is_serving() so the Runner's existing self-heal beat performs a
 * full teardown+rebind, its proven recovery path. The persistent host client
 * talks every couple of seconds, so a healthy deployment never trips this. */
#define kUnservableTicks 3600UL      /* ~60 s unable to accept + wire-quiet */
static unsigned long gUnservableSince = 0;

/* Reconnect displacement (client-crash recovery, 2026-07-17). The reap tiers
 * above free a leaked-close corpse on a TIMER — Tier 3 at ~3 min. But a held
 * slot only matters when someone actually wants to connect, and a NEW
 * connection arriving while the single slot is held is itself the strongest
 * evidence the held peer is gone: a live single-client consumer never opens a
 * second. So when a T_LISTEN lands on a busy worker whose held connection has
 * ALSO been wire-quiet past this short window (a client mid-verb keeps
 * gLastActive fresh every round-trip, so it is never displaced), abort the
 * corpse immediately instead of waiting out the timer. The newcomer's retry a
 * beat later lands on the freed slot — turning "client crashed -> up to 3 min
 * of deafness" into a reconnect-and-go, without a guest reboot. Measured: a
 * SIGTERM'd MirrorApp whose close was leaked took 180 s (Tier 3) to recover;
 * this makes the reconnect the recovery. */
#define kDisplaceQuietTicks 240UL    /* ~4 s wire-quiet before a reconnect wins */
/* Refusal counter. A refused T_LISTEN is INVISIBLE in the log today — the
 * notifier cannot log (not deferred-task safe), so a client that opens a socket
 * per request and gets refused sees a bare connection reset with nothing on the
 * guest side to explain it. That silence cost a day: refusals were read as
 * tracking-loop starvation and a healthy verb was written up as poisoning the
 * session (2026-07-29/30). The notifier bumps this; ot_idle reports it from the
 * main loop, where logging is safe. */
static volatile unsigned long gRefusedConns = 0;
static unsigned long          gRefusedLogged = 0;

static volatile int gReconnectWaiting = 0;  /* a T_LISTEN was refused on a busy
                                             * worker — arms the fast idle reap */

/* --- notifier-side helpers (deferred-task time; OT calls only) ------------ */

/* Drain available bytes into gRbuf. Called on T_DATA, and re-called from
 * ot_idle after a line is consumed. A full gRbuf is BACKPRESSURE, not an error:
 * stop draining and leave the rest in OT's internal buffer (TCP flow control
 * holds the peer), so pipelined request lines are never dropped. T_DATA is
 * edge-triggered — once we stop early, only the ot_idle re-pump picks the
 * remainder up. The oversized-single-line resync lives in ot_idle, which can
 * tell "full with no newline" (bad line) from "full of pipelined lines". */
static void ot_pump_recv(void)
{
    OTFlags  flags;
    OTResult n;

    if (gState == kStIdle) {
        return;                          /* not connected */
    }
    while (gRlen < sizeof(gRbuf)) {
        n = OTRcv(gWorker, gRbuf + gRlen,
                  (OTByteCount)(sizeof(gRbuf) - gRlen), &flags);
        gStatRcvCalls++;
        if (n > 0) {
            gRlen += (OTByteCount)n;
            gConnSawData = 1;
            gStatRcvBytes += (unsigned long)n;
            if ((unsigned long)gRlen > gStatRcvHighWater) {
                gStatRcvHighWater = (unsigned long)gRlen;
            }
        } else {
            break;                       /* kOTNoDataErr (drained) or an error */
        }
    }
}

/* Push as much of gResp as flow control allows. Called to start a send (main
 * loop, inside OTEnterNotifier) and to continue it (notifier, on T_GODATA). */
static void ot_pump_send(void)
{
    OTResult r;

    if (gState != kStSending) {
        return;
    }
    if (!otsched_can_send(&gSendSchedule, &gOTConfig)) {
        if (gOTConfig.enabled) {
            gStatPaceDeferred++;
        }
        return;
    }
    while (gSent < gRespLen) {
        OTByteCount contribution = gRespLen - gSent;

        if (gOTConfig.enabled
            && contribution > gOTConfig.contribution_limit) {
            contribution = gOTConfig.contribution_limit;
        }
        r = OTSnd(gWorker, gResp + gSent, contribution, 0);
        gSendCalls++;
        gStatSndCalls++;
        if (r > 0) {
            gSent += (OTByteCount)r;
            gSendBytes += (unsigned long)r;
            gStatSndBytes += (unsigned long)r;
            gStatSndContributions++;
            if (gOTConfig.enabled
                && otsched_positive(&gSendSchedule, &gOTConfig, ot_now_us(),
                                    gSent < gRespLen)) {
                gStatPaceArms++;
                return;
            }
        } else if (r == kOTFlowErr) {
            gSendFlow++;
            gStatSndFlow++;
            if (gOTConfig.enabled) {
                otsched_flow_blocked(&gSendSchedule);
            }
            return;                      /* resume on T_GODATA */
        } else {
            gState = kStRecv;            /* error/disconnect: abandon this reply */
            gRespLen = 0;
            gSent = 0;
            otsched_reset(&gSendSchedule, &gOTConfig);
            gSendEnd = TickCount();
            gSendDone = 1;
            return;
        }
    }
    gState = kStRecv;                    /* fully sent; ready for the next line */
    gRespLen = 0;
    gSent = 0;
    otsched_reset(&gSendSchedule, &gOTConfig);
    gSendEnd = TickCount();
    gSendDone = 1;
}

static pascal void ot_notifier(void *ctx, OTEventCode code, OTResult result,
                               void *cookie)
{
    OT_ENTER_A5();
    (void)cookie;

    {
        int w = gTraceW & 31;
        gTraceCode[w] = code;
        gTraceRes[w]  = result;
        gTraceW++;
    }

    if (ctx == kTagListener) {
        switch (code) {
        case T_LISTEN:
            OTMemzero(&gCall, sizeof(gCall));
            gCall.addr.buf    = (UInt8 *)&gPeer;
            gCall.addr.maxlen = sizeof(gPeer);
            if (OTListen(gListener, &gCall) == noErr) {
                /* Accept ONLY when the worker is genuinely back to T_IDLE. After
                 * a prior connection's orderly release (T_ORDREL below), the
                 * worker lingers in T_OUTREL for a beat, so this pre-check cuts
                 * most doomed accepts. But it is only advisory: OTAccept is
                 * async, so the endpoint can still fail between here and
                 * T_ACCEPTCOMPLETE - which is handled below, the real safety
                 * net. If not ready, refuse; the client retries. */
                if (gState == kStIdle
                    && OTGetEndpointState(gWorker) == T_IDLE
                    && OTAccept(gListener, gWorker, &gCall) == noErr) {
                    /* queued; success -> T_PASSCON, failure -> T_ACCEPTCOMPLETE */
                } else {
                    /* Busy/not-ready: refuse. A reconnect knocking on the held
                     * single slot is the strongest signal the previous client
                     * is gone — so ARM the demand-sensitive reap (handled in
                     * ot_idle, where aborting gWorker is safe under the proven
                     * OTEnterNotifier bracket; doing it here, from the
                     * listener's notifier, leaves gWorker unable to re-accept).
                     * The main-loop reap then frees a wire-quiet corpse in ~4 s
                     * instead of the ~3 min idle tier, and this client's retry
                     * lands. kOTLookErr means the peer's own disconnect for
                     * this indication is already pending — consume that
                     * instead, or the indication leaks and the listener goes
                     * deaf. */
                    gRefusedConns++;        /* ot_idle logs this; see above */
                    if (gState != kStIdle) {
                        gReconnectWaiting = 1;
                    }
                    if (OTSndDisconnect(gListener, &gCall) == kOTLookErr) {
                        (void)OTRcvDisconnect(gListener, NULL);
                    }
                }
            }
            break;
        case T_ACCEPTCOMPLETE:
            /* The async accept resolved. On failure (the accept-vs-release race,
             * kOTOutStateErr) the connection request is still queued on the
             * listener; with qlen 1 the listener then delivers NO further
             * T_LISTEN until it is cleared - the permanent-wedge mechanism
             * (measured 2026-07-05). Dispose it here so the listener frees up;
             * the worker returns to T_IDLE on its own and the client's retry
             * lands. This is the fix that makes the wedge self-healing. */
            if (result != noErr) {
                if (OTSndDisconnect(gListener, &gCall) == kOTLookErr) {
                    (void)OTRcvDisconnect(gListener, NULL);
                }
            }
            break;
        case T_DISCONNECT:
            /* The peer aborted a connection indication still QUEUED on the
             * listener (client RST while waiting to be accepted or refused).
             * Consume it, or the qlen-1 listener never delivers another
             * T_LISTEN: new connections then sit in the TCP backlog, accepted
             * but never serviced - the PB1400c wedge of 2026-07-07, reproduced
             * on the emulator by RST-closing right after the request (docs/09,
             * correction 3). Consuming also invalidates any in-flight refuse
             * for the same indication; its kOTBadSequenceErr completion is
             * harmless. With qlen 1 the indication is unambiguous, so the
             * TDiscon detail can be discarded. */
            (void)OTRcvDisconnect(gListener, NULL);
            gAbortedIndications++;
            break;
        default:
            break;
        }
    } else {  /* worker */
        switch (code) {
        case T_PASSCON:                  /* accept finished: connected */
            gRlen = 0;
            gConnFresh = 1;
            gConnSawData = 0;
            otsched_reset(&gSendSchedule, &gOTConfig);
            gState = kStRecv;
            break;
        case T_DATA:
            ot_pump_recv();
            break;
        case T_GODATA:
            if (gOTConfig.enabled) {
                otsched_flow_ready(&gSendSchedule);
            }
            ot_pump_send();
            break;
        case T_DISCONNECT:
            (void)OTRcvDisconnect(gWorker, NULL);
            gRlen = 0;
            gRespLen = 0;
            gSent = 0;
            otsched_reset(&gSendSchedule, &gOTConfig);
            gState = kStIdle;            /* worker returns to T_IDLE, reusable */
            break;
        case T_ORDREL:
            (void)OTRcvOrderlyDisconnect(gWorker);
            (void)OTSndOrderlyDisconnect(gWorker);
            gRlen = 0;
            gRespLen = 0;
            gSent = 0;
            otsched_reset(&gSendSchedule, &gOTConfig);
            gState = kStIdle;
            break;
        default:
            break;
        }
    }

    OT_LEAVE_A5();
}

/* --- setup / teardown (main loop, synchronous) ---------------------------- */

OSStatus ot_startup(void)
{
    return InitOpenTransport();
}

void ot_shutdown(void)
{
    CloseOpenTransport();
}

void ot_configure(const OTConfig *config)
{
    OTConfig resolved = { 0, 0, 0, 0, 1 };

    if (config != NULL && config->enabled
        && config->contribution_limit > 0
        && config->burst_contributions > 0
        && config->resume_us > 0) {
        resolved = *config;
        if (resolved.contribution_limit > 1448) {
            resolved.contribution_limit = 1448;
        }
        if (resolved.burst_contributions > 16) {
            resolved.burst_contributions = 16;
        }
        if (resolved.resume_us > 1000000UL) {
            resolved.resume_us = 1000000UL;
        }
        if (resolved.rx_drain_lines == 0) {
            resolved.rx_drain_lines = 1;
        } else if (resolved.rx_drain_lines > 8) {
            resolved.rx_drain_lines = 8;
        }
    }
    gOTConfig = resolved;
    otsched_reset(&gSendSchedule, &gOTConfig);
}

/* Open, bind (synchronously), install the notifier, then go async+non-blocking. */
static OSStatus ot_open_bind(EndpointRef *epOut, void *tag, OTQLen qlen,
                             InetPort port)
{
    OSStatus    err;
    EndpointRef ep;

    ep = OTOpenEndpoint(OTCreateConfiguration(kTCPName), 0, NULL, &err);
    if (ep == NULL || err != noErr) {
        return (err != noErr) ? err : -1;
    }
    err = OTInstallNotifier(ep, gNotifyUPP, tag);
    if (err == noErr) {
        InetAddress addr;
        TBind       req;
        OTInitInetAddress(&addr, port, kOTAnyInetAddress);
        OTMemzero(&req, sizeof(req));
        req.addr.buf = (UInt8 *)&addr;
        req.addr.len = sizeof(addr);
        req.qlen     = qlen;
        err = OTBind(ep, (qlen > 0) ? &req : NULL, NULL);  /* sync */
    }
    if (err == noErr) {
        err = OTSetAsynchronous(ep);
    }
    if (err == noErr) {
        err = OTSetNonBlocking(ep);
    }
    if (err != noErr) {
        OTCloseProvider(ep);
        return err;
    }
    *epOut = ep;
    return noErr;
}

OSStatus ot_serve(InetPort port, OTReqHandler handler, OTLogProc log)
{
    OSStatus err;

    gHandler = handler;
    gLog     = log;
    gState   = kStIdle;
    gRlen    = 0;
    gRespLen = 0;
    gSent    = 0;
    otsched_reset(&gSendSchedule, &gOTConfig);
    gInconSince         = 0;
    gAbortedIndications = 0;
    gAbortedLogged      = 0;
    gConnFresh          = 0;
    gConnSawData        = 0;
    gConnSince          = 0;
    gUnservableSince    = 0;
    OT_CAPTURE_A5();

    gNotifyUPP = NewOTNotifyUPP(ot_notifier);
    if (gNotifyUPP == NULL) {
        return -1;
    }
    err = ot_open_bind(&gListener, kTagListener, 1, port);  /* qlen 1 */
    if (err != noErr) {
        ot_teardown();
        return err;
    }
    err = ot_open_bind(&gWorker, kTagWorker, 0, port);      /* qlen 0 */
    if (err != noErr) {
        ot_teardown();
        return err;
    }
    return noErr;
}

void ot_teardown(void)
{
    gRespLen = 0;
    gSent = 0;
    otsched_reset(&gSendSchedule, &gOTConfig);
    if (gWorker != NULL) {
        (void)OTSndOrderlyDisconnect(gWorker);
        (void)OTUnbind(gWorker);
        (void)OTCloseProvider(gWorker);
        gWorker = NULL;
    }
    if (gListener != NULL) {
        (void)OTUnbind(gListener);
        (void)OTCloseProvider(gListener);
        gListener = NULL;
    }
    if (gNotifyUPP != NULL) {
        DisposeOTNotifyUPP(gNotifyUPP);
        gNotifyUPP = NULL;
    }
}

Boolean ot_is_sending(void)
{
    return (gState == kStSending);
}

long ot_sleep_ticks(long idleTicks)
{
    /* Hot while a reply is draining or activity was recent - the window is
     * what keeps the loop hot between our reply going out and the client's
     * next request arriving. Deliberately NOT `gRlen > 0`: a stalled partial
     * line would pin the loop hot forever; buffer *growth* is stamped in
     * ot_idle instead, so a stall decays to the idle sleep within the window.
     * Unsigned subtraction is wrap-safe. */
    if (gState == kStSending
        || (TickCount() - gLastActive) < kActiveWindow) {
        gStatSleepHot++;
        return 0;
    }
    gStatSleepCold++;
    return idleTicks;
}

void ot_stats_snapshot(OTStats *stats)
{
    if (stats == NULL) {
        return;
    }
    stats->rcv_calls = gStatRcvCalls;
    stats->rcv_bytes = gStatRcvBytes;
    stats->rcv_high_water = gStatRcvHighWater;
    stats->snd_calls = gStatSndCalls;
    stats->snd_bytes = gStatSndBytes;
    stats->snd_flow_events = gStatSndFlow;
    stats->snd_contributions = gStatSndContributions;
    stats->pace_arms = gStatPaceArms;
    stats->pace_fires = gStatPaceFires;
    stats->pace_deferred = gStatPaceDeferred;
    stats->lines_drained = gStatLinesDrained;
    stats->lines_dispatched = gStatLinesDispatched;
    stats->dispatch_ticks = gStatDispatchTicks;
    stats->sleep_hot = gStatSleepHot;
    stats->sleep_cold = gStatSleepCold;
}

Boolean ot_is_serving(void)
{
    if (gListener == NULL) {
        return false;
    }
    if (gUnservableSince != 0
        && TickCount() - gUnservableSince > kUnservableTicks) {
        return false;
    }
    return true;
}

/* --- main-loop pump ------------------------------------------------------- */

static int ot_extract_line(size_t *linelen)
{
#ifdef TBT_CONTROL_HTTP
    size_t message_len = 0;
    size_t consumed = 0;
    tbt_frame_result frame;

    *linelen = 0;
    OTEnterNotifier(gWorker);
    ot_pump_recv();
    frame = tbt_control_frame_length(
        gRbuf, (size_t)gRlen, sizeof(gRbuf), &message_len);
    if (frame == TBT_FRAME_COMPLETE) {
        consumed = message_len;
        *linelen = gRbuf[0] == '{' ? message_len - 1U : message_len;
        memcpy(gLine, gRbuf, *linelen);
        memmove(gRbuf, gRbuf + consumed, (size_t)gRlen - consumed);
        gRlen -= (OTByteCount)consumed;
    } else if (frame < 0) {
        gRlen = 0;
    }
    OTLeaveNotifier(gWorker);
    return frame == TBT_FRAME_COMPLETE;
#else
    size_t i;
    int have = 0;

    *linelen = 0;
    OTEnterNotifier(gWorker);
    ot_pump_recv();
    for (i = 0; i < (size_t)gRlen; i++) {
        if (gRbuf[i] == '\n') {
            have = 1;
            *linelen = i;
            break;
        }
    }
    if (have) {
        size_t consumed = *linelen + 1;

        memcpy(gLine, gRbuf, *linelen);
        memmove(gRbuf, gRbuf + consumed, (size_t)gRlen - consumed);
        gRlen -= (OTByteCount)consumed;
    } else if (gRlen >= sizeof(gRbuf)) {
        gRlen = 0;
    }
    OTLeaveNotifier(gWorker);
    return have;
#endif
}

static void ot_dispatch_line(size_t linelen)
{
    unsigned long dispatchStart;
    int rn;

    gLastActive = TickCount();
    gStatLinesDispatched++;
    dispatchStart = TickCount();
    rn = (gHandler != NULL)
       ? gHandler(gLine, linelen, gResp, sizeof(gResp))
       : 0;
    gStatDispatchTicks += TickCount() - dispatchStart;

    /* A handler that returns <= 0 sends NOTHING, and used to do so silently —
     * which is indistinguishable on the wire from a wedge, and cost real time
     * chasing `axdo` (2026-07-29: no send line in the log, no reply, and no
     * clue which of the two it was). Say so, and say how long the handler held
     * the main loop: a long dispatch is the signal that the guest was starved
     * rather than broken, because ot_idle — and every watchdog tier in it —
     * cannot run while we are in here. */
    {
        unsigned long held = TickCount() - dispatchStart;

        if (rn <= 0 && gLog != NULL) {
            char b[96];
            (void)snprintf(b, sizeof(b),
                           "dispatch: NO REPLY (rn=%d) after %lu ticks",
                           rn, held);
            gLog(b);
        } else if (held > 60UL && gLog != NULL) {   /* > ~1 s on the main loop */
            char b[96];
            (void)snprintf(b, sizeof(b),
                           "dispatch: held the main loop %lu ticks (reply %d B)",
                           held, rn);
            gLog(b);
        }
    }

    if (rn <= 0) {
        return;
    }

    gRespLen = (OTByteCount)rn;
    OTEnterNotifier(gWorker);
    gSent = 0;
    otsched_reset(&gSendSchedule, &gOTConfig);
    gSendStart = TickCount();
    gSendCalls = 0;
    gSendFlow = 0;
    gSendBytes = 0;
    gSendDone = 0;
    gState = kStSending;
    ot_pump_send();
    OTLeaveNotifier(gWorker);
}

void ot_idle(void)
{
    /* 0. adaptive-poll stamp: the notifier grows gRlen at deferred-task time;
     * seeing it move from the main loop means bytes just arrived. */
    {
        static OTByteCount prevRlen = 0;
        if (gRlen != prevRlen) {
            prevRlen = gRlen;
            if (gRlen > 0) {
                gLastActive = TickCount();
            }
        }
    }

    /* 0b. report refused connections from the main loop. The client sees a bare
     * reset; this is the guest's side of that story, and it names the cause
     * ("you opened a second socket while the slot was busy") instead of leaving
     * a reset to be misdiagnosed. */
    if (gRefusedConns != gRefusedLogged) {
        unsigned long now_refused = gRefusedConns;

        if (gLog != NULL) {
            char b[112];
            (void)snprintf(b, sizeof(b),
                           "refused %lu connection(s) on a busy slot "
                           "(total %lu) - client must reconnect",
                           now_refused - gRefusedLogged, now_refused);
            gLog(b);
        }
        gRefusedLogged = now_refused;
    }

    /* 1. drain the notifier's event trace to the log. */
    while (gTraceR != gTraceW) {
        int r = gTraceR & 31;
        if (gLog != NULL) {
            char b[48];
            (void)snprintf(b, sizeof(b), "OT evt=0x%lx r=%ld",
                           (unsigned long)gTraceCode[r], (long)gTraceRes[r]);
            gLog(b);
        }
        gTraceR++;
    }

    /* 1b. when a send has finished, log its shape: bytes, OTSnd calls, flow
     * stalls, and wall-clock ticks. This is what tells us where the metal 20 s
     * lives. Logged from the main loop (gSendDone is the handoff flag). */
    if (gSendDone) {
        gSendDone = 0;
        gLastActive = TickCount();       /* reply just left: expect a follow-up */
        if (gLog != NULL) {
            char b[96];
            (void)snprintf(b, sizeof(b),
                           "send: bytes=%lu calls=%ld flow=%ld ticks=%ld",
                           (unsigned long)gSendBytes, (long)gSendCalls,
                           (long)gSendFlow,
                           (long)(gSendEnd - gSendStart));
            gLog(b);
        }
    }

    /* 1c. surface aborted-indication recoveries (counted in the notifier,
     * where logging isn't allowed). One line per occurrence keeps the wedge
     * class visible in harness.log without wire noise. */
    if (gAbortedLogged != gAbortedIndications) {
        gAbortedLogged = gAbortedIndications;
        if (gLog != NULL) {
            char b[64];
            (void)snprintf(b, sizeof(b),
                           "listener: aborted indication consumed (#%ld)",
                           gAbortedLogged);
            gLog(b);
        }
    }

    /* 1d. listener watchdog: an indication stuck in T_INCON past the grace
     * window means the notifier handshake leaked it (a failure shape we did
     * not enumerate - the enumerated ones are handled inline above). Re-pull
     * it here and apply the same accept-or-refuse rule, so the failure decays
     * to a logged hiccup instead of permanent deafness. Main-loop code, so
     * hold the notifier off while touching the endpoints. */
    if (gListener != NULL && OTGetEndpointState(gListener) == T_INCON) {
        if (gInconSince == 0) {
            gInconSince = TickCount();
        } else if (TickCount() - gInconSince > kInconGraceTicks) {
            OTResult lr;

            gInconSince = 0;
            OTEnterNotifier(gListener);
            OTMemzero(&gCall, sizeof(gCall));
            gCall.addr.buf    = (UInt8 *)&gPeer;
            gCall.addr.maxlen = sizeof(gPeer);
            lr = OTListen(gListener, &gCall);
            if (lr == noErr) {
                if (gState == kStIdle
                    && OTGetEndpointState(gWorker) == T_IDLE
                    && OTAccept(gListener, gWorker, &gCall) == noErr) {
                    /* late accept: the parked client gets served after all */
                } else if (OTSndDisconnect(gListener, &gCall) == kOTLookErr) {
                    (void)OTRcvDisconnect(gListener, NULL);
                }
            } else if (lr == kOTLookErr) {
                (void)OTRcvDisconnect(gListener, NULL);
            }
            OTLeaveNotifier(gListener);
            if (gLog != NULL) {
                char b[64];
                (void)snprintf(b, sizeof(b),
                               "listener watchdog: re-armed (OTListen %ld)",
                               (long)lr);
                gLog(b);
            }
        }
    } else {
        gInconSince = 0;
    }

    /* 1e. connection watchdog: stamp a fresh accept from the main loop, then
     * apply the two-tier reap — byteless past the short window, or wire-quiet
     * past the long window even after traffic (a leaked peer close otherwise
     * parks the slot forever). The condition is re-evaluated under the held
     * notifier so progress racing the deadline wins and the connection
     * stays. */
    if (gConnFresh) {
        gConnFresh = 0;
        gConnSince = TickCount();
    }
    if (gState == kStIdle) {
        gConnSince = 0;
        gReconnectWaiting = 0;   /* slot free: no corpse for a newcomer to evict */
    } else if (gWorker != NULL && gConnSince != 0) {
        unsigned long now = TickCount();
        int byteless = !gConnSawData
            && now - gConnSince > kSilentConnTicks;
        int stalled = gRlen > 0
            && now - gLastActive > kStalledFrameTicks;
        /* A reconnect refused on the busy slot collapses the idle-held window
         * from ~3 min to ~4 s: the newcomer is the evidence the held peer is
         * gone, and a client mid-verb keeps gLastActive fresh every round-trip
         * so it is never caught by the short window. No new-client demand ->
         * the metal-verified long window is unchanged. */
        unsigned long idleWindow = gReconnectWaiting ? kDisplaceQuietTicks
                                                     : kIdleConnTicks;
        int quiet = gRlen == 0
            && now - gConnSince > idleWindow
            && now - gLastActive > idleWindow;

        if (byteless || stalled || quiet) {
            int dropped = 0;

            OTEnterNotifier(gWorker);
            if (gState != kStIdle
                && ((byteless && !gConnSawData)
                    || (stalled && gRlen > 0)
                    || (quiet && gRlen == 0))) {
                if (OTSndDisconnect(gWorker, NULL) == kOTLookErr) {
                    (void)OTRcvDisconnect(gWorker, NULL);
                }
                gRlen = 0;
                gRespLen = 0;
                gSent = 0;
                otsched_reset(&gSendSchedule, &gOTConfig);
                gState = kStIdle;
                dropped = 1;
            }
            OTLeaveNotifier(gWorker);
            if (dropped) {
                gConnSince = 0;
            }
            if (dropped && gLog != NULL) {
                gLog(stalled
                     ? "worker watchdog: dropped stalled partial frame"
                     : gConnSawData
                     ? "worker watchdog: dropped idle held connection"
                     : "worker watchdog: dropped silent connection");
            }
        }
    }

    /* 1f. servability stamp for the catch-all above: accept-ready or any
     * recent wire progress clears it; anything else starts (or continues)
     * the unservable clock. */
    {
        /* Both endpoints must be healthy: a free worker is useless behind a
         * listener jammed in phantom T_INCON (state says an indication is
         * pending, OTListen says kOTNoDataErr, and no new T_LISTEN is ever
         * delivered — observed on the PB1400c after a client crash-storm of
         * RSTs; the 1d re-pull cannot clear it). */
        int workerReady = gWorker != NULL && gState == kStIdle
            && OTGetEndpointState(gWorker) == T_IDLE;
        int listenerJammed = gListener != NULL
            && OTGetEndpointState(gListener) == T_INCON;
        int acceptReady = workerReady && !listenerJammed;
        int progressed = gUnservableSince != 0
            && (long)(gLastActive - gUnservableSince) > 0;

        if (acceptReady || progressed) {
            gUnservableSince = 0;
        } else if (gUnservableSince == 0) {
            gUnservableSince = TickCount();
        }
    }

    /* 2. A paced send resumes only from this main-loop monotonic gate.
     * T_GODATA may clear flow pressure, but cannot bypass pacing. */
    if (gOTConfig.enabled && gSendSchedule.gate_armed) {
        unsigned long long gateNow = ot_now_us();

        if (otsched_gate_due(&gSendSchedule, gateNow)) {
            if (gWorker != NULL && gState == kStSending) {
                OTEnterNotifier(gWorker);
                if (otsched_fire_gate(&gSendSchedule, &gOTConfig, gateNow)) {
                    gStatPaceFires++;
                    ot_pump_send();
                }
                OTLeaveNotifier(gWorker);
            } else {
                otsched_reset(&gSendSchedule, &gOTConfig);
            }
        }
    }

    /* 3. Policy-off retains one-line dispatch. An active policy may drain a
     * bounded number of buffered lines, but a response immediately restores
     * strict single-owner ordering by changing gState to kStSending. */
    if (gState == kStRecv) {
        unsigned short lines = 0;
        unsigned short drainLimit = 1;

        if (gOTConfig.enabled
            && (TickCount() - gLastActive) < kActiveWindow) {
            drainLimit = gOTConfig.rx_drain_lines;
        }
        while (gState == kStRecv && lines < drainLimit) {
            size_t linelen;

            if (!ot_extract_line(&linelen)) {
                break;
            }
            lines++;
            gStatLinesDrained++;
            ot_dispatch_line(linelen);
        }
    }
}
