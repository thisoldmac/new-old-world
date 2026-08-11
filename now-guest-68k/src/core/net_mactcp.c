/*
 * net_mactcp.c - MacTCP transport for NOW-68K. Implements net.h.
 *
 * Descendant of chat/client/src/net_mactcp.c (the closest existing thing:
 * parse-free entry points, the ULP-timeout-with-abort-action open, and
 * release_stream()'s TCPAbort-then-TCPRelease funnel), rebuilt around
 * net.h's queue/drain interface instead of that file's send/recv-a-line
 * shape. The difference is not cosmetic: net.h's interface exists
 * specifically so the one-op-in-flight rule can live IN HERE, where a
 * caller has no way to violate it, rather than in caller discipline.
 *
 * ONE-OP-IN-FLIGHT POLICY (net.h's rule 1) and why neither side starves:
 *
 *   gOp is OP_NONE, OP_SEND, OP_RECV or OP_CLOSE - never more than one at a
 *   time (OP_CLOSE is net_close()'s orderly TCPClose, DEFECT 6 - it is
 *   posted from OP_NONE exactly like a send or receive and obeys the same
 *   rule). When net_idle() finds OP_NONE it always prefers a queued send
 *   over posting a new receive, and it does NOT post a receive speculatively:
 *
 *       OP_NONE -> gSendLen > 0        ?  post TCPSend
 *               -> gClosing            ?  post TCPClose
 *               -> bytes already held  ?  post TCPRcv
 *               -> otherwise              leave the slot free
 *
 *   A send can therefore never be blocked behind a *newly started* receive.
 *   It CAN be blocked behind a receive already posted before the send was
 *   queued - one async op, once issued, runs to completion, and there is no
 *   way to preempt it without tearing down the stream. The original design
 *   accepted that and bounded it with a kRecvPollSecs command timeout.
 *
 *   MEASURED ON METAL, that bound WAS the latency. On the PowerBook 180c
 *   round trips ran 57-178 ticks while MacTCP Ping over the same link ran
 *   0-24: a spread of 121 ticks, which is exactly the 120-tick poll. Every
 *   ping was waiting out the remainder of a receive that had nothing to
 *   deliver, so the reported number described our own arbitration and barely
 *   involved the network.
 *
 *   So we ask before we commit: bytes_waiting() is a local TCPStatus query
 *   (its own parameter block, no network I/O) and a receive is posted only
 *   when MacTCP is already holding bytes, or when the connection has stopped
 *   being established so the close still surfaces through the normal
 *   completion path. The slot now stays free for sends nearly always, and
 *   kRecvPollSecs is a backstop for a receive we chose to post rather than a
 *   tax on every send. The timeout is still NOT an error - MacTCP completes
 *   the TCPRcv with commandTimeout, the connection stays open, and net_idle()
 *   treats it as "nothing arrived" and re-evaluates.
 *
 *   The reverse direction - a receive starved by a relentless stream of
 *   sends - cannot happen either: each TCPSend is a single bounded write
 *   of whatever is staged *at post time* (see gSendPosted below), so it
 *   always completes and returns to OP_NONE, where the same OP_NONE check
 *   runs again. A queue that never stops growing would still eventually
 *   yield to a receive once net_queue_send's callers (wire68.h: a hello, a
 *   30 s ping, one frame at a time) stop producing faster than one MacTCP
 *   round trip drains - which is the same assumption the whole polled
 *   model already rests on. Unread inbound bytes are not lost meanwhile:
 *   they sit in MacTCP's own stream buffer (gStreamBuf, sized for the
 *   ~8 KB window MacTCP advertises regardless - see kStreamBuf below) and
 *   TCP flow control simply pauses the peer once that fills, which is the
 *   correct backpressure behaviour, not a bug.
 *
 * OUTBOUND STAGING (gSendBuf) is a queue, not a single message slot, so a
 * caller can queue while a send is in flight. gSendPosted records how many
 * bytes of gSendBuf were handed to the *outstanding* TCPSend; anything
 * net_queue_send appends after that point lands at gSendBuf[gSendPosted..]
 * and beyond, which the in-flight WDS (captured by pointer+length at post
 * time) never reads - so append-while-sending needs no lock, not even a
 * flag, on this single-threaded polled model. On completion: if nothing
 * was appended mid-flight (gSendLen == gSendPosted, the common case) the
 * buffer is simply empty again; otherwise the unsent tail is memmove'd
 * down to the front.
 *
 * NOTHING RUNS AT INTERRUPT TIME (net.h's rule 2): every PBControlAsync
 * call below has ioCompletion = NULL and is polled via gPB.ioResult from
 * net_idle(), which is called only from the main event loop. The only
 * PBControlSync calls (TCPCreate, and the TCPAbort/TCPRelease teardown
 * funnel) are synchronous Toolbox calls made from that same main-loop
 * context, never from a completion routine - there isn't one.
 *
 * DEFECT 5 (FIXED): this paragraph used to go on to claim that a NULL
 * ioCompletion therefore means Virtual Memory cannot bite us. That is
 * false and net.h's rule 2 has been corrected to say so: the Device
 * Manager writes ioResult into gPB at interrupt time regardless of
 * whether a completion routine exists, and the .IPP driver copies inbound
 * bytes into gRecvBuf from its own interrupt-level receive path. gPB,
 * gStreamBuf, gSendBuf and gRecvBuf are ordinary BSS; under VM a page-out
 * of any of them followed by an interrupt-time touch is a bus error. We
 * are only safe today because VM is OFF on the test machine - a standing
 * precondition, not something this file implements. HoldMemory over the
 * parameter block and every buffer is still unimplemented; see net.h.
 */
#include "net.h"

#include <Devices.h>          /* OpenDriver, PBControlSync/Async, ParmBlkPtr */
#include <Events.h>           /* TickCount - net_sleep_ticks' activity window */
#include <MacTCP.h>
#include <string.h>

/* ---- buffer budget ---------------------------------------------------
 *
 * kStreamBuf: MacTCP's own TCPCreate rcvBuff - the kernel-side pool that
 * backs the advertised receive window. finding mactcp-8k-window-knee
 * (metal-verified on a Quadra 950 over the same BlueSCSI DaynaPORT
 * hardware this PowerBook uses) says MacTCP advertises roughly an 8 KB
 * window regardless of the size passed here, and a write larger than the
 * window stalls ~220 ms per chunk on delayed-ACK window updates. 8192 is
 * the proven figure already adopted twice in this lab for exactly that
 * reason (chat/client/src/net_mactcp.c's kStreamBuf, and the negotiated
 * chunk size in hello.h - NOW68K_HELLO_CHUNK is 4096, deliberately half
 * this, so one chunk plus header never chases the window edge).
 *
 * kSendCap / kRecvCap: our own staging/accumulation buffers, sized to one
 * negotiated chunk (hello.h's NOW68K_HELLO_CHUNK = 4096) plus a frame
 * header (NOW68K_FRAME_HEADER_BYTES = 8) plus slack for a second small
 * control message (a ping/pong is a few dozen bytes) queued alongside it
 * without forcing net_queue_send's documented short-accept path in the
 * common case: 4096 + 8 = 4104, rounded up to 4608.
 *
 * Total static: 8192 + 4608 + 4608 = 17408 bytes, better than the chat
 * client's 8+8+8 = 24576 (net.h's own reference point for "this scale or
 * better"), which matters more here: this milestone targets a 4 MB / 384 KB
 * partition PowerBook 180c, not chat's target.
 */
#define kStreamBuf 8192UL
#define kSendCap   4608UL
#define kRecvCap   4608UL

/* Bound on how long a posted TCPRcv can hold the floor before net_idle()
 * re-checks whether a send is waiting - see the file header's starvation
 * argument. Short enough that a queued ping or frame is never held back
 * by more than a couple of seconds; long enough not to turn a quiet
 * connection into a busy-poll of the network stack. commandTimeoutValue
 * is a single signed byte (SInt8, max 127), so this has to stay small
 * regardless. */
#define kRecvPollSecs 2

/* net_sleep_ticks' hot-polling window after any wire activity, ticks
 * (60/s) - same figure and same reasoning as harness/src/mactcp.c's
 * kActiveWindow: a round trip crosses net_idle() several times, and each
 * crossing pays the WaitNextEvent sleep unless the loop stays hot. */
#define kActiveWindowTicks 60UL

/* DEFECT 4: bound on how long teardown_stream() polls for an async op that
 * was in flight at abort time to settle before releasing the stream. An
 * aborted call completes via MacTCP's own deferred task, which runs at
 * interrupt time very soon after TCPAbort - this is a safety net against
 * "very soon" turning into "never", not an expected wait. */
#define kAbortSettleTicks 60UL

/* DEFECT 6: bound on how long net_close() waits (across repeated net_idle()
 * calls) for the send flush + orderly TCPClose to finish before net_idle()
 * gives up and falls back to an abort. Generous relative to one MacTCP
 * round trip, still bounded so a quitting app is never hung waiting on a
 * peer that stopped reading. */
#define kCloseTimeoutTicks 180UL

enum { OP_NONE = 0, OP_SEND, OP_RECV, OP_CLOSE };

static short     gDriver = 0;
static StreamPtr gStream = 0;
static NetState  gState  = kNetIdle;
static int       gOp     = OP_NONE;
static TCPiopb   gPB;                    /* the one op in flight, ever */

/* TCPStatus runs on its OWN parameter block, never gPB. It is a local query
 * of the driver's bookkeeping - it starts no network I/O and completes
 * immediately - but issuing it through gPB would overwrite the state of
 * whatever async operation is genuinely in flight. Separate block, no
 * interaction with the one-op-in-flight rule. */
static TCPiopb   gStatusPB;

static char          gStreamBuf[kStreamBuf];

static char          gSendBuf[kSendCap];
static unsigned long gSendLen    = 0;    /* total staged, incl. any in-flight tail */
static unsigned long gSendPosted = 0;    /* bytes handed to the outstanding TCPSend, 0 = none */
static wdsEntry       gWds[2];

static char          gRecvBuf[kRecvCap];
/* DEFECT 1: gRecvLen used to be both "bytes buffered" and "offset the next
 * TCPRcv is posted at", and net_take() compacted (memmove'd) the buffer on
 * every drain - including while a TCPRcv it had no way to know about was
 * still writing into gRecvBuf at the OLD offset. Compacting shrank gRecvLen
 * out from under that in-flight write; completion then did gRecvLen +=
 * rcvBuffLen against the now-smaller value, so the reader believed the
 * newly-arrived bytes started at offset 0 when they were physically sitting
 * higher up, and replayed stale already-consumed bytes as a frame header.
 * Fix: split "first unread byte" (gRecvHead) from "unread byte count"
 * (gRecvLen) and never move buffer contents while a receive can be writing
 * into it. net_take() only ever advances gRecvHead and shrinks gRecvLen -
 * head+len is the offset a posted TCPRcv target sits at, and that sum is
 * invariant under net_take() (head+n, len-n), so an outstanding receive's
 * write target never moves no matter how many times the caller drains
 * during the wait. Compaction (memmove back to offset 0) happens only in
 * post_recv(), which by construction only runs when gOp == OP_NONE - no
 * receive can be outstanding to race. */
static unsigned long gRecvHead = 0;      /* offset of first unread byte */
static unsigned long gRecvLen  = 0;      /* unread byte count, starting at gRecvHead */

static short          gClosing        = 0;   /* net_close() in progress */
static unsigned long  gCloseStartTicks = 0;  /* TickCount() at net_close() */

static unsigned long gLastActive = 0;    /* TickCount of last wire activity */

static char gErrBuf[32];                 /* net_last_error() - zero-init = "" */

/* ---- small helpers, no stdio (log.h's rationale for File Manager over
 * stdio - keeping newlib's stdio tail out of the link - applies here too:
 * this is the only place in the module that would otherwise want it). ---- */

static void append_decimal(char *out, long cap, long value)
{
    char tmp[12];
    unsigned long v;
    int  n = 0;
    int  neg = 0;
    long i = 0;

    if (cap <= 0) {
        return;
    }
    if (value < 0) {
        neg = 1;
        v = (unsigned long)(-(value));
    } else {
        v = (unsigned long)value;
    }
    do {
        tmp[n++] = (char)('0' + (int)(v % 10));
        v /= 10;
    } while (v > 0 && n < (int)sizeof(tmp));

    if (neg && (i + 1) < cap) {
        out[i++] = '-';
    }
    while (n > 0 && (i + 1) < cap) {
        out[i++] = tmp[--n];
    }
    out[i] = '\0';
}

static const char *err_name(OSErr code)
{
    switch (code) {
    case connectionClosing:     return "peer closing";
    case connectionDoesntExist: return "no connection";
    case connectionTerminated:  return "connection terminated";
    case insufficientResources: return "insufficient resources";
    case openFailed:            return "open failed";
    case duplicateSocket:       return "duplicate socket";
    default:                    return NULL;
    }
}

static void set_error(OSErr code)
{
    const char *name = err_name(code);

    if (name != NULL) {
        strcpy(gErrBuf, name);   /* every entry above is well under sizeof(gErrBuf) */
        return;
    }
    strcpy(gErrBuf, "err ");
    append_decimal(gErrBuf + 4, (long)sizeof(gErrBuf) - 4, (long)code);
}

static void touch_active(void)
{
    gLastActive = TickCount();
}

/* The shared teardown funnel - TCPAbort then TCPRelease, synchronously,
 * exactly once per stream. net_disconnect() and net_idle()'s error paths
 * both route here (net.h's "single failure funnel", the -23009 leaked-
 * stream warning); they differ only in the NetState left behind: a
 * caller-driven disconnect leaves kNetIdle, an internal wire error leaves
 * kNetFailed so net_last_error() still has something to say (net.h draws
 * those apart on purpose - kNetIdle is "never tried", kNetFailed is "last
 * attempt failed"). Safe to call when gStream is already 0. */
static void teardown_stream(void)
{
    TCPiopb pb;
    unsigned long start;
    volatile short *outstanding;   /* see DEFECT 4 comment below */

    if (gStream == 0) {
        return;
    }
    memset(&pb, 0, sizeof(pb));
    pb.ioCRefNum = gDriver;
    pb.csCode    = TCPAbort;
    pb.tcpStream = gStream;
    (void)PBControlSync((ParmBlkPtr)&pb);

    /* DEFECT 4 (FIXED): this used to go straight to TCPRelease. gPB may
     * still hold an async op TCPAbort just terminated (a connect, send or
     * receive posted against THIS stream) - MacTCP completes an aborted
     * async call at interrupt time via a deferred task, not synchronously
     * inside TCPAbort. If that deferred completion lands after TCPRelease,
     * and after a subsequent net_connect() has memset(&gPB, ...) for a
     * fresh TCPCreate/TCPActiveOpen on a NEW stream, it stamps ioResult =
     * connectionTerminated over that fresh call's result. net_idle() then
     * reads the new connect as having failed, tears down, and retries -
     * forever, on a connect that never actually ran. So: poll gPB itself
     * (the same parameter block the outstanding op used) until it settles,
     * bounded, before releasing. gPB.ioResult is written by that deferred
     * task at interrupt time while this loop spins with no function calls
     * inside it, so it is read through a volatile pointer - without that
     * the compiler is free to hoist the load at -O2 and spin forever even
     * after the real value changes underneath it. */
    outstanding = &gPB.ioResult;
    start = TickCount();
    while (*outstanding > 0
           && (unsigned long)(TickCount() - start) < kAbortSettleTicks) {
        /* empty: bounded synchronous wait, not net_idle()'s polled-from-
         * the-event-loop pattern. */
    }
    gOp = OP_NONE;

    memset(&pb, 0, sizeof(pb));
    pb.ioCRefNum = gDriver;
    pb.csCode    = TCPRelease;
    pb.tcpStream = gStream;
    (void)PBControlSync((ParmBlkPtr)&pb);

    gStream = 0;
}

static OSErr create_stream(void)
{
    OSErr err;

    memset(&gPB, 0, sizeof(gPB));
    gPB.ioCRefNum    = gDriver;
    gPB.csCode       = TCPCreate;
    gPB.ioCompletion = NULL;
    gPB.csParam.create.rcvBuff    = gStreamBuf;
    gPB.csParam.create.rcvBuffLen = sizeof(gStreamBuf);
    gPB.csParam.create.notifyProc = NULL;
    err = PBControlSync((ParmBlkPtr)&gPB);
    if (err == noErr) {
        gStream = gPB.tcpStream;
    }
    return err;
}

static void post_send(void)
{
    gWds[0].length = (unsigned short)gSendLen;
    gWds[0].ptr    = gSendBuf;
    gWds[1].length = 0;
    gWds[1].ptr    = NULL;

    memset(&gPB, 0, sizeof(gPB));
    gPB.ioCRefNum    = gDriver;
    gPB.csCode       = TCPSend;
    gPB.tcpStream    = gStream;
    gPB.ioCompletion = NULL;
    /* No per-call ulpTimeoutValue override (validityFlags left 0): the
     * stream-level ULP timeout set once at TCPActiveOpen (abort action)
     * already bounds a send against a peer that stops reading. */
    gPB.csParam.send.ulpTimeoutValue  = 0;
    gPB.csParam.send.ulpTimeoutAction = 0;
    gPB.csParam.send.pushFlag         = true;
    gPB.csParam.send.urgentFlag       = false;
    gPB.csParam.send.wdsPtr           = (Ptr)gWds;
    gPB.ioResult = inProgress;
    (void)PBControlAsync((ParmBlkPtr)&gPB);
    gSendPosted = gSendLen;
    gOp = OP_SEND;
}

/* Bytes MacTCP already holds for us, and whether the connection is still
 * established. Both come from one local TCPStatus - no network round trip.
 *
 * This exists because of a latency defect measured on the PowerBook 180c:
 * we used to park a TCPRcv with a kRecvPollSecs command timeout whenever
 * nothing else was queued, so a ping queued one tick later had to wait out
 * the remainder of that poll before the send could take the single operation
 * slot. Measured round trips ran 57-178 ticks against MacTCP Ping's 0-24 over
 * the same link - a spread of 121 ticks, which is exactly the 120-tick poll.
 * We were timing our own arbitration, not the network.
 *
 * The fix is to stop parking a receive speculatively: ask first, and post a
 * TCPRcv only when there is something to collect (or when the connection has
 * stopped being established, so the existing completion path still sees the
 * close). The slot then stays free for sends almost all of the time, and
 * kRecvPollSecs goes back to being a backstop rather than a latency tax. */
static unsigned short bytes_waiting(short *establishedOut)
{
    if (gStream == 0 || gDriver == 0) {
        if (establishedOut != NULL) {
            *establishedOut = 0;
        }
        return 0;
    }
    memset(&gStatusPB, 0, sizeof(gStatusPB));
    gStatusPB.ioCRefNum   = gDriver;
    gStatusPB.tcpStream   = gStream;
    gStatusPB.csCode      = TCPStatus;
    gStatusPB.ioCompletion = NULL;
    if (PBControlSync((ParmBlkPtr)&gStatusPB) != noErr) {
        /* A failed status query is not evidence of anything; let the normal
         * completion paths decide the connection's fate. */
        if (establishedOut != NULL) {
            *establishedOut = 1;
        }
        return 0;
    }
    if (establishedOut != NULL) {
        *establishedOut =
            (short)(gStatusPB.csParam.status.connectionState == 8);
    }
    return gStatusPB.csParam.status.amtUnreadData;
}

static void post_recv(void)
{
    /* DEFECT 1: reclaim head space here, and only here. This runs solely
     * from net_idle()'s OP_NONE case, i.e. only when no receive is
     * outstanding, so moving buffer contents now cannot race a TCPRcv that
     * is mid-write into gRecvBuf - unlike doing it in net_take(), which can
     * be called at any time including while OP_RECV is in flight. */
    if (gRecvHead != 0) {
        if (gRecvLen != 0) {
            memmove(gRecvBuf, gRecvBuf + gRecvHead, gRecvLen);
        }
        gRecvHead = 0;
    }

    memset(&gPB, 0, sizeof(gPB));
    gPB.ioCRefNum    = gDriver;
    gPB.csCode       = TCPRcv;
    gPB.tcpStream    = gStream;
    gPB.ioCompletion = NULL;
    /* Bounded, not 0 ("wait forever") - see the file header's starvation
     * argument: this is what lets a queued send get a turn. */
    gPB.csParam.receive.commandTimeoutValue = kRecvPollSecs;
    /* Posted at gRecvHead(==0)+gRecvLen; net_take() preserves that sum as
     * bytes are drained (head advances, len shrinks by the same amount),
     * so this is exactly where the driver will still be writing when the
     * op completes, regardless of how many net_take() calls happened
     * while it was outstanding. */
    gPB.csParam.receive.rcvBuff    = gRecvBuf + gRecvLen;
    gPB.csParam.receive.rcvBuffLen = (unsigned short)(kRecvCap - gRecvLen);
    gPB.ioResult = inProgress;
    (void)PBControlAsync((ParmBlkPtr)&gPB);
    gOp = OP_RECV;
}

static void post_close(void)
{
    memset(&gPB, 0, sizeof(gPB));
    gPB.ioCRefNum    = gDriver;
    gPB.csCode       = TCPClose;
    gPB.tcpStream    = gStream;
    gPB.ioCompletion = NULL;
    /* validityFlags left 0: inherit the stream's ULP timeout/action set at
     * TCPActiveOpen. net_idle()'s own kCloseTimeoutTicks bound covers us
     * regardless if the driver-level timeout is looser than that. */
    gPB.csParam.close.ulpTimeoutValue  = 0;
    gPB.csParam.close.ulpTimeoutAction = 0;
    gPB.csParam.close.validityFlags    = 0;
    gPB.ioResult = inProgress;
    (void)PBControlAsync((ParmBlkPtr)&gPB);
    gOp = OP_CLOSE;
}

short net_init(void)
{
    Str255 name;
    OSErr  err;

    /* ".IPP" built by hand, not the compiler's "\p" extension (matches
     * chat/harness convention in this codebase). */
    name[0] = 4;
    name[1] = '.';
    name[2] = 'I';
    name[3] = 'P';
    name[4] = 'P';
    err = OpenDriver(name, &gDriver);
    if (err != noErr) {
        gDriver = 0;
        set_error(err);
        gState = kNetFailed;
        return (short)err;
    }

    /* DEFECT 19 (FIXED): this used to call create_stream() here too. The
     * first net_connect() immediately threw that stream away - it routes
     * through net_disconnect() first (its own comment: "even on a fresh
     * net_init() stream"), which tears down whatever exists and creates a
     * new one. Wasteful, and it was also the stream that leaked: if the
     * app quit without ever calling net_connect(), net_shutdown() ->
     * net_disconnect() -> teardown_stream() needs gStream != 0 to do
     * anything, and nothing here set it. The stream's life now begins at
     * the first net_connect() (or a reconnect, same call) and ends at
     * net_disconnect()/net_shutdown(); teardown_stream()'s existing
     * gStream == 0 guard makes "never connected" a correct no-op, and the
     * "connected, then quit" path is unchanged since net_connect() already
     * owns creation.
     */
    gState = kNetIdle;
    return 0;
}

void net_shutdown(void)
{
    net_disconnect();
    /* .IPP is system-shared; leave the driver open (chat/harness convention). */
}

void net_disconnect(void)
{
    teardown_stream();
    gState      = kNetIdle;
    gOp         = OP_NONE;
    gSendLen    = 0;
    gSendPosted = 0;
    gRecvLen    = 0;
    gRecvHead   = 0;
    gClosing    = 0;    /* abortive teardown always wins over an in-progress net_close() */
}

short net_connect(unsigned long ip, unsigned short port,
                  unsigned short timeout_secs)
{
    OSErr err;

    /* Always through the same funnel first - a no-op when there is no
     * stream yet (net_init() no longer creates one; DEFECT 19), and what
     * lets net_connect be called again after a failure without ever
     * holding two streams (net.h's -23009 warning). Either way the stream
     * must be (re)created below. */
    net_disconnect();

    if (gDriver == 0) {
        set_error(-1);
        gState = kNetFailed;
        return -1;
    }

    err = create_stream();
    if (err != noErr) {
        set_error(err);
        gState = kNetFailed;
        return (short)err;
    }

    /* ulpTimeoutValue is a signed byte (SInt8, max 127); connfields.h
     * already floors the human-facing field at 1 s and caps it at 60 s,
     * comfortably inside that range. Clamped defensively here anyway,
     * since net.h's own signature promises nothing about the range of
     * timeout_secs beyond "caller-supplied". */
    if (timeout_secs < 1) {
        timeout_secs = 1;
    } else if (timeout_secs > 127) {
        timeout_secs = 127;
    }

    memset(&gPB, 0, sizeof(gPB));
    gPB.ioCRefNum    = gDriver;
    gPB.csCode       = TCPActiveOpen;
    gPB.tcpStream    = gStream;
    gPB.ioCompletion = NULL;
    gPB.csParam.open.remoteHost          = (ip_addr)ip;
    gPB.csParam.open.remotePort          = (tcp_port)port;
    gPB.csParam.open.localPort           = 0;
    gPB.csParam.open.ulpTimeoutValue     = (SInt8)timeout_secs;
    gPB.csParam.open.ulpTimeoutAction    = 1;      /* abort: fail bounded, not hang */
    gPB.csParam.open.validityFlags       = 0xC0;   /* timeoutValue | timeoutAction */
    gPB.csParam.open.commandTimeoutValue = 0;
    gPB.ioResult = inProgress;
    (void)PBControlAsync((ParmBlkPtr)&gPB);

    gState      = kNetConnecting;
    gOp         = OP_NONE;
    gSendLen    = 0;
    gSendPosted = 0;
    gRecvLen    = 0;
    gRecvHead   = 0;
    gClosing    = 0;
    touch_active();
    return 0;
}

/* DEFECT 6 (FIXED): net.h declared this verb with no implementation here,
 * so the guest had no way to send the contract-required farewell on a
 * clean quit - only net_disconnect()'s abortive TCPAbort existed, which
 * discards whatever `bye` net_queue_send() had staged before it ever
 * reaches the wire. This just arms the closing sequence; net_idle() (which
 * the caller is already required to keep calling) does the actual work:
 * drain gSendLen via the ordinary post_send() path exactly as it would
 * anyway, then post_close() once nothing is left to flush, then release
 * on completion - falling back to an abortive teardown if that whole
 * sequence has not finished within kCloseTimeoutTicks. */
void net_close(void)
{
    if (gState != kNetConnected) {
        return;                     /* nothing live to close gracefully */
    }
    gClosing         = 1;
    gCloseStartTicks = TickCount();
}

NetState net_state(void)
{
    return gState;
}

const char *net_last_error(void)
{
    return gErrBuf;
}

long net_queue_send(const void *buf, long len)
{
    long room;
    long n;

    if (buf == NULL || len <= 0) {
        return 0;
    }
    room = (long)kSendCap - (long)gSendLen;
    if (room <= 0) {
        return 0;
    }
    n = (len < room) ? len : room;
    memcpy(gSendBuf + gSendLen, buf, (size_t)n);
    gSendLen += (unsigned long)n;
    touch_active();
    return n;
}

long net_take(void *buf, long cap)
{
    long n;

    if (buf == NULL || cap <= 0 || gRecvLen == 0) {
        return 0;
    }
    n = (cap < (long)gRecvLen) ? cap : (long)gRecvLen;
    /* DEFECT 1: no memmove here - see gRecvHead's declaration comment.
     * Copy out of the head, then advance the head and shrink the count.
     * gRecvBuf itself is never rewritten by this function, so a TCPRcv
     * that is concurrently writing further up the buffer (post_recv()
     * posted it at the offset gRecvHead+gRecvLen had at post time) is
     * never disturbed, no matter when or how many times a caller drains
     * while that receive is outstanding. */
    memcpy(buf, gRecvBuf + gRecvHead, (size_t)n);
    gRecvHead += (unsigned long)n;
    gRecvLen  -= (unsigned long)n;
    return n;
}

short net_is_sending(void)
{
    /* gOp == OP_SEND implies gSendLen > 0 (post_send sets gSendPosted =
     * gSendLen, and both only reach 0 together on completion), so this
     * single check covers "staged but not yet posted" and "sending". */
    return (short)(gSendLen > 0);
}

long net_sleep_ticks(long idle_ticks)
{
    if (gState == kNetConnecting
        || net_is_sending()
        || (TickCount() - gLastActive) < kActiveWindowTicks) {
        return 0;
    }
    return idle_ticks;
}

void net_idle(void)
{
    /* Bounded spin so several already-completed transitions collapse into
     * one call (harness/src/mactcp.c's ot_idle precedent) instead of each
     * arrow waiting for its own WaitNextEvent wake. Every reachable state
     * either returns (blocked on an in-flight op, or nothing to do) or
     * strictly advances gState/gOp, so 4 is generous, not just adequate:
     * the longest real chain here is RECV-done -> NONE -> post SEND, two
     * steps. */
    short spins;

    for (spins = 0; spins < 4; spins++) {
        if (gState == kNetConnecting) {
            if (gPB.ioResult > 0) {
                return;                        /* TCPActiveOpen still in flight */
            }
            if (gPB.ioResult == noErr) {
                gState = kNetConnected;
                gOp    = OP_NONE;
                gErrBuf[0] = '\0';
                touch_active();
                continue;
            }
            set_error((OSErr)gPB.ioResult);
            teardown_stream();
            gState = kNetFailed;
            return;
        }

        if (gState != kNetConnected) {
            return;                            /* kNetIdle / kNetFailed: nothing to drive */
        }

        /* DEFECT 6: bounded fallback for net_close(). Checked on every
         * entry to this loop - including entries from later net_idle()
         * calls, not just this one - so a close that never finishes
         * (peer stopped reading, TCPClose itself hangs) cannot hold the
         * caller's shutdown loop past kCloseTimeoutTicks regardless of
         * which sub-step (send flush or the TCPClose itself) it stalled
         * in. Routes through the same abort-then-poll-then-release funnel
         * as every other failure path. */
        if (gClosing
            && (unsigned long)(TickCount() - gCloseStartTicks) >= kCloseTimeoutTicks) {
            teardown_stream();
            gState      = kNetIdle;
            gOp         = OP_NONE;
            gClosing    = 0;
            gSendLen    = 0;
            gSendPosted = 0;
            gRecvLen    = 0;
            gRecvHead   = 0;
            return;
        }

        switch (gOp) {
        case OP_NONE:
            if (gSendLen > 0) {
                post_send();                   /* flush staged bytes first, close or not */
            } else if (gClosing) {
                post_close();                  /* DEFECT 6: nothing left to flush - close now */
            } else if (gRecvLen < kRecvCap) {
                short established = 1;
                if (bytes_waiting(&established) > 0 || !established) {
                    /* Only claim the slot when there is something to collect,
                     * or when the connection has stopped being established so
                     * the receive completes immediately with the close. */
                    post_recv();
                } else {
                    return;                    /* nothing pending; leave the
                                                  slot free for the next send */
                }
            } else {
                return;                        /* recv buffer full; wait for net_take */
            }
            continue;

        case OP_SEND:
            if (gPB.ioResult > 0) {
                return;                        /* TCPSend still in flight */
            }
            if (gPB.ioResult != noErr) {
                set_error((OSErr)gPB.ioResult);
                teardown_stream();
                gState = kNetFailed;
                return;
            }
            if (gSendLen == gSendPosted) {
                gSendLen = 0;                   /* nothing appended mid-flight */
            } else {
                memmove(gSendBuf, gSendBuf + gSendPosted, gSendLen - gSendPosted);
                gSendLen -= gSendPosted;
            }
            gSendPosted = 0;
            gOp = OP_NONE;
            touch_active();
            continue;

        case OP_RECV:
            if (gPB.ioResult > 0) {
                return;                        /* TCPRcv still in flight */
            }
            if (gPB.ioResult == noErr || gPB.ioResult == commandTimeout) {
                /* DEFECT 9 (FIXED): a commandTimeout completion used to be
                 * treated as "nothing arrived" and gPB.csParam.receive.
                 * rcvBuffLen was never consulted on that path. But MacTCP
                 * can complete a timed-out TCPRcv with data already copied
                 * into rcvBuff - the timeout and the inbound data are not
                 * mutually exclusive, they race - so those bytes were
                 * silently dropped and the stream desynced exactly like
                 * DEFECT 1 did. Both completion kinds now run the same
                 * bookkeeping; only actual errors below skip it.
                 *
                 * Trust rcvBuffLen only on these two completion kinds - on
                 * a close/error, MacTCP leaves the requested size in it
                 * rather than zeroing (harness/src/mactcp.c's ot_idle
                 * lesson; net.h repeats the same warning), which is why
                 * the else-error branch below must not add it in. */
                gRecvLen += gPB.csParam.receive.rcvBuffLen;
                if (gPB.csParam.receive.rcvBuffLen > 0) {
                    touch_active();
                }
                gOp = OP_NONE;
            } else {
                set_error((OSErr)gPB.ioResult);
                teardown_stream();
                gState = kNetFailed;
                return;
            }
            continue;

        case OP_CLOSE:
            if (gPB.ioResult > 0) {
                return;                        /* TCPClose still in flight */
            }
            /* Whether the orderly close completed cleanly or with an error,
             * we are done trying: release now rather than duplicating
             * teardown_stream()'s abort-then-release funnel. TCPAbort on an
             * already-closed stream is a harmless no-op (its result is
             * ignored, as it already is on every other path through this
             * funnel), so routing through it here costs nothing. This is
             * the success half of DEFECT 6; the timeout fallback above is
             * the other half. */
            teardown_stream();
            gState      = kNetIdle;
            gOp         = OP_NONE;
            gClosing    = 0;
            gSendLen    = 0;
            gSendPosted = 0;
            gRecvLen    = 0;
            gRecvHead   = 0;
            return;

        default:
            return;
        }
    }
}
