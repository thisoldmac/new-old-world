/*
 * P6's liveness CHANNEL - the resident's own connection to the host, and
 * the journey the vehicle in now_liveness.c exists to carry.
 * ------------------------------------------------------------------
 * WHAT THIS IS FOR, in one paragraph. A Macintosh is cooperatively
 * scheduled, so one blocked application starves all of them. Liveness on
 * this wire is answered BY an application (`ping` every 30 s, by
 * contract), and a modal dialog is exactly what takes the application
 * away - so on 2026-08-05 an ordinary Finder alert silenced the whole
 * machine for over ninety seconds and the host, whose silence window is
 * ~75 s, declared a perfectly healthy Macintosh gone. This connection is
 * the machine answering for itself while no application can.
 *
 * WHY IT IS A SECOND CONNECTION AND NOT THE APPLICATION'S. The smaller
 * change would be to send the existing `ping` on the endpoint the
 * application already owns. It is wrong, and the reason is framing
 * rather than safety: the application may be mid-transfer when this code
 * decides to ping, the frame codec has no provision for two writers on
 * one stream, and a host that cannot decode a frame DROPS THE
 * CONNECTION. A resident ping could therefore cause the exact disconnect
 * it exists to prevent - rarely, and unreproducibly.
 *
 * WHY MacTCP AND NOT OPEN TRANSPORT. Answered by the linker rather than
 * by argument, and much the cheaper place to find it: OT's 68K libraries
 * are CFM/Shared Library Manager fragments and this extension is a flat
 * 68K code resource, so they do not link (four library combinations, 15
 * unresolved symbols at best). The Device Manager is TRAPS - `PBOpen`
 * and `PBControl` need no library at all - and OS 9's Open Transport
 * still provides the `.IPP` driver for exactly these callers.
 *
 * THE ONE DESIGN DECISION WORTH ARGUING WITH: NO COMPLETION ROUTINES.
 * The plan expected register-based completion routines, each needing the
 * assembly-shim treatment `now_liveness_tm.S` had just charged for. They
 * are not used, and the reason is that they would buy nothing here.
 *
 *   - This component already has a periodic interrupt-time context. A
 *     completion routine's only advantage is learning of a result before
 *     the next tick, and nothing here is in a hurry: the whole channel's
 *     job is one frame every thirty seconds.
 *   - The ABI question is genuinely open for these callbacks in a way it
 *     was not for the Time Manager. Timer.h's own procinfo said
 *     unambiguously that the record arrives in A1. MacTCP.h declares its
 *     completion `CALLBACK_API_C(void, ...)(TCPiopb *)` - a STACK-based
 *     UPP - while the Device Manager's documented convention hands a
 *     completion routine A0 and D0. One of those is wrong for this
 *     runtime and the header does not say which. A wrong answer here
 *     costs a five-second corruption of somebody else's memory, which is
 *     precisely the failure that disarmed the vehicle for a day.
 *   - `ioResult` is the SAME fact the completion routine would carry,
 *     read from memory instead of from a callback: the Device Manager
 *     sets it before it calls anybody. Polling it needs no ABI to be
 *     right.
 *
 * So every call here is issued asynchronously with a nil completion and
 * reaped by the next tick. If a future need ever makes the latency
 * matter, the shim is the answer and now_liveness_tm.S is the pattern -
 * but it should be added for a reason, not for symmetry.
 *
 * THE DISCIPLINE. `now_liveness_net_pump` runs at INTERRUPT TIME. It
 * allocates nothing, blocks on nothing, and calls no Toolbox routine
 * that could move memory. Every buffer it uses is a static in this
 * component's own globals, which live at fixed system-heap addresses for
 * the life of the boot (`_start` calls RETRO68_RELOCATE and never frees
 * them - the same fact now_ext_gne.S relies on to reach its own
 * globals). The only Toolbox it calls is PBControlAsync, which queues.
 *
 * WHAT IT DOES NOT DO. It never reads a reply for meaning. The host
 * answers `pong` and the contract permits nothing else on this channel,
 * so the receive path exists only to keep MacTCP's buffer from filling.
 * A resident that parsed replies would be a second command lane, and the
 * host refuses one by name.
 */

#include <Devices.h>
#include <MacTCP.h>
#include <MacTypes.h>

#include "peek_table.h"
#include "wire_limits.h"

/* The resident's own version string. It is NOT the application's and
   must not borrow it: the two halves are separately deployable, and a
   channel reporting the version of a binary it is not is worse than one
   reporting nothing. Display only, per the contract. */
#define kNowResidentVersion "0.1"

enum {
    /* MacTCP refuses a stream buffer under 4 KB. Doubled, because this
       buffer is where a host's replies accumulate between the drains
       below and running it close would trade memory this component has
       for a failure mode it does not need. */
    kRcvBuffLen = 8192,
    /* One frame out. The largest thing this channel ever sends is its
       hello, and the two variable parts of that are a 31-byte machine
       name and a 31-byte OS string. */
    kSendBuffLen = 320,
    /* Replies are drained, never read. Small on purpose: a big buffer
       here would only mean more bytes discarded per call. */
    kDrainBuffLen = 256,

    /* Ticks between pings, in units of the vehicle's own 5 s cadence.
       FIVE, so ~30 s - the countdown is spent on the tick that reaches
       zero AND on the one that sends, so this is one less than the six
       an off-by-one reading suggests. Measured on the emulator at 35 s
       with six, which is the reason the number is written down here
       rather than reasoned about. And it is not chosen here: The contract
       says the guest pings after 30 s of wire silence and the host
       declares a guest gone after ~75 s; both are stated where both
       sides read them, and a third independently-chosen number is the
       shape of defect AGENTS.md names as this project's costliest. */
    kPingEveryTicks = 5,
    /* Ticks to wait after a refused dial. The host may simply not be up
       yet - a Macintosh booted before the Mac it talks to is the normal
       case, not an error - so this backs off and tries again rather than
       latching a failure nobody can clear without a reboot. */
    kRetryTicks = 12,
    /* How many event-loop passes may try to create the stream.
       ------------------------------------------------------------------
       This wants to be ONE - a synchronous Toolbox call in the hot path
       of every application on the machine is the shape of defect this
       component exists to avoid, and the driver probe beside it is
       deliberately once-only for exactly that reason.
       It is not one because of WHEN this first runs: the jGNE filter's
       first pass is somewhere in the booting Finder, and a stack that has
       answered `PBOpen` may still not be ready to create a stream. A
       single failed attempt there would latch "this machine has no
       transport" for the whole boot, and it would latch it in the one
       field a person reads to decide whether MacTCP works here.
       Five is small enough to stay a rounding error - five calls in the
       life of a boot, not five per pass - and only a FAILED attempt is
       ever retried. */
    kPrepareTries = 5
};

/* What is in flight on the control param block, so the reap knows what
   it just reaped. There is only ever one, which is the whole reason this
   is a word rather than a queue. */
enum {
    kInFlightNone = 0,
    kInFlightOpen,
    kInFlightSend,
    kInFlightAbort
};

static short gRefNum;                 /* the .IPP driver, or 0 */
static short gPrepareTries;
static StreamPtr gStream;
static Boolean gStreamReady;
static Boolean gConnected;
static Boolean gHelloSent;
static short gInFlight;
static short gRetryCountdown;
static short gPingCountdown;
static NowPeekU32 gDialledEpoch;

static TCPiopb gCtlPB;                /* open, send, abort */
static TCPiopb gRcvPB;                /* the drain, independently in flight */
static Boolean gRcvInFlight;
static wdsEntry gWDS[2];

static unsigned char gRcvBuff[kRcvBuffLen];
static unsigned char gSendBuff[kSendBuffLen];
static unsigned char gDrainBuff[kDrainBuffLen];

/* ---------------------------------------------------------------- */
/* Building a frame, without a formatter.                            */
/*                                                                   */
/* There is no snprintf at interrupt time and there does not need to  */
/* be: every message this channel sends is constants, two Pascal      */
/* strings out of the shared table, and one small integer. These are  */
/* byte appends with a cap, and each one silently stops at the cap -  */
/* a truncated hello is refused by the host and reported, where a     */
/* buffer overrun is not reported by anybody.                         */
/* ---------------------------------------------------------------- */

typedef struct {
    unsigned char *buf;
    unsigned long len;
    unsigned long cap;
    Boolean overflowed;
} Build;

static void put_byte(Build *b, unsigned char c)
{
    if (b->len < b->cap) {
        b->buf[b->len++] = c;
    } else {
        b->overflowed = true;
    }
}

static void put_cstr(Build *b, const char *s)
{
    while (*s != '\0') {
        put_byte(b, (unsigned char)*s++);
    }
}

/* A Pascal string out of the shared table, JSON-escaped.

   Only the two escapes JSON requires structurally are emitted; a control
   character becomes '_' rather than a \u sequence, because a machine
   name containing one is not a case worth carrying a hex formatter into
   an interrupt for. Bytes over 0x7F pass through UNCHANGED and
   deliberately: this string's whole job is to fingerprint identically to
   the name the application's own hello carries, and a resident that
   sanitised what the application sent raw would be a channel the host
   could not attach to anything. */
static void put_pascal_json(Build *b, const unsigned char *p,
                            unsigned long cap)
{
    unsigned long n = p[0];
    unsigned long i;

    if (n > cap - 1) {
        n = cap - 1;
    }
    for (i = 1; i <= n; ++i) {
        unsigned char c = p[i];

        if (c == '"' || c == '\\') {
            put_byte(b, '\\');
            put_byte(b, c);
        } else if (c < 0x20) {
            put_byte(b, '_');
        } else {
            put_byte(b, c);
        }
    }
}

static void put_u32(Build *b, NowPeekU32 v)
{
    unsigned char digits[10];
    int n = 0;

    if (v == 0) {
        put_byte(b, '0');
        return;
    }
    while (v > 0 && n < 10) {
        digits[n++] = (unsigned char)('0' + (v % 10));
        v /= 10;
    }
    while (n > 0) {
        put_byte(b, digits[--n]);
    }
}

/* The 8-byte control-frame header, built byte-wise rather than overlaid.
   Both this chip and the wire are big-endian so an overlay would happen
   to work here - and "happens to work on one side" is the bug this
   project keeps shipping (contract/wire_limits.h says so at length). */
static unsigned long finish_frame(Build *b)
{
    unsigned long payload;

    if (b->overflowed) {
        return 0;
    }
    payload = b->len - NOW_WIRE_FRAME_HEADER_BYTES;
    b->buf[0] = NOW_WIRE_CHANNEL_CONTROL;
    b->buf[1] = NOW_WIRE_FLAG_END;
    b->buf[2] = 0;                    /* transfer id: control frames use 0 */
    b->buf[3] = 0;
    b->buf[4] = (unsigned char)((payload >> 24) & 0xFF);
    b->buf[5] = (unsigned char)((payload >> 16) & 0xFF);
    b->buf[6] = (unsigned char)((payload >> 8) & 0xFF);
    b->buf[7] = (unsigned char)(payload & 0xFF);
    return b->len;
}

static void begin_frame(Build *b)
{
    b->buf = gSendBuff;
    b->len = NOW_WIRE_FRAME_HEADER_BYTES;
    b->cap = kSendBuffLen;
    b->overflowed = false;
}

/* `role: resident` is what makes this connection possible at all, and
   not decoration. The contract refuses a dial repeating the name of a
   live session as busy, and this channel shares its machine's name BY
   DESIGN - sharing it is how the host associates the two. Without the
   role it would be refused busy by its own application. */
static unsigned long build_hello(const NowPeekTable *table)
{
    Build b;

    begin_frame(&b);
    put_cstr(&b, "{\"type\":\"hello\",\"contract\":");
    put_u32(&b, (NowPeekU32)NOW_WIRE_CONTRACT_REVISION);
    put_cstr(&b, ",\"side\":\"guest\",\"role\":\"resident\",\"version\":\""
                 kNowResidentVersion "\",\"name\":\"");
    put_pascal_json(&b, table->endpoint.guest_name,
                    sizeof table->endpoint.guest_name);
    put_cstr(&b, "\",\"os\":\"");
    put_pascal_json(&b, table->endpoint_os, sizeof table->endpoint_os);
    put_cstr(&b, "\"}");
    return finish_frame(&b);
}

static unsigned long build_ping(NowPeekU32 id)
{
    Build b;

    begin_frame(&b);
    put_cstr(&b, "{\"type\":\"ping\",\"id\":");
    put_u32(&b, id);
    put_cstr(&b, "}");
    return finish_frame(&b);
}

/* ---------------------------------------------------------------- */
/* The transport.                                                    */
/* ---------------------------------------------------------------- */

static void issue_send(NowPeekTable *table, unsigned long len)
{
    if (len == 0) {
        return;                       /* a builder that overflowed */
    }
    gWDS[0].length = (unsigned short)len;
    gWDS[0].ptr = (Ptr)gSendBuff;
    gWDS[1].length = 0;               /* the terminator MacTCP looks for */
    gWDS[1].ptr = NULL;

    gCtlPB.ioCompletion = NULL;
    gCtlPB.ioCRefNum = gRefNum;
    gCtlPB.csCode = TCPSend;
    gCtlPB.tcpStream = gStream;
    gCtlPB.csParam.send.ulpTimeoutValue = 30;
    gCtlPB.csParam.send.ulpTimeoutAction = 1;   /* abort, do not hang */
    gCtlPB.csParam.send.validityFlags = timeoutValue | timeoutAction;
    gCtlPB.csParam.send.pushFlag = true;
    gCtlPB.csParam.send.urgentFlag = false;
    gCtlPB.csParam.send.wdsPtr = (Ptr)gWDS;
    gCtlPB.csParam.send.sendFree = 0;
    gCtlPB.csParam.send.sendLength = 0;
    gCtlPB.csParam.send.userDataPtr = NULL;
    if (PBControlAsync((ParmBlkPtr)&gCtlPB) == noErr) {
        gInFlight = kInFlightSend;
    } else {
        table->channel_result = (NowPeekI32)gCtlPB.ioResult;
        table->channel_state = kNowPeekChannelFailed;
    }
}

static void issue_abort(void)
{
    gCtlPB.ioCompletion = NULL;
    gCtlPB.ioCRefNum = gRefNum;
    gCtlPB.csCode = TCPAbort;
    gCtlPB.tcpStream = gStream;
    gCtlPB.csParam.abort.userDataPtr = NULL;
    gConnected = false;
    gHelloSent = false;
    if (PBControlAsync((ParmBlkPtr)&gCtlPB) == noErr) {
        gInFlight = kInFlightAbort;
    }
}

static void issue_open(NowPeekTable *table,
                       const NowPeekLivenessEndpoint *want)
{
    int i;

    gCtlPB.ioCompletion = NULL;
    gCtlPB.ioCRefNum = gRefNum;
    gCtlPB.csCode = TCPActiveOpen;
    gCtlPB.tcpStream = gStream;
    gCtlPB.csParam.open.ulpTimeoutValue = 30;
    gCtlPB.csParam.open.ulpTimeoutAction = 1;   /* abort rather than hang */
    gCtlPB.csParam.open.validityFlags = timeoutValue | timeoutAction;
    gCtlPB.csParam.open.commandTimeoutValue = 30;
    gCtlPB.csParam.open.remoteHost = (ip_addr)want->host_ipv4;
    gCtlPB.csParam.open.remotePort = (tcp_port)want->host_port;
    gCtlPB.csParam.open.localHost = 0;
    gCtlPB.csParam.open.localPort = 0;          /* any; MacTCP assigns */
    gCtlPB.csParam.open.tosFlags = 0;
    gCtlPB.csParam.open.precedence = 0;
    gCtlPB.csParam.open.dontFrag = 0;
    gCtlPB.csParam.open.timeToLive = 0;
    gCtlPB.csParam.open.security = 0;
    gCtlPB.csParam.open.optionCnt = 0;
    for (i = 0; i < 40; ++i) {
        gCtlPB.csParam.open.options[i] = 0;
    }
    gCtlPB.csParam.open.userDataPtr = NULL;
    gDialledEpoch = want->endpoint_epoch;
    if (PBControlAsync((ParmBlkPtr)&gCtlPB) == noErr) {
        gInFlight = kInFlightOpen;
        table->channel_state = kNowPeekChannelOpening;
    } else {
        table->channel_result = (NowPeekI32)gCtlPB.ioResult;
        table->channel_state = kNowPeekChannelFailed;
        gRetryCountdown = kRetryTicks;
    }
}

/* Keep MacTCP's stream buffer from filling with replies nobody reads.
   The host answers every ping with a pong and the contract allows it
   nothing else on this channel, so these bytes are discarded unexamined
   - see the header on why reading them would make this a command lane. */
static void drain(void)
{
    if (gRcvInFlight) {
        if (gRcvPB.ioResult > 0) {
            return;                   /* still waiting for bytes */
        }
        gRcvInFlight = false;
        /* Any error at all: the connection is gone or going, and the
           control path will find out the same way on its next send.
           Nothing to report here that is not reported better there. */
        if (gRcvPB.ioResult != noErr) {
            return;
        }
    }
    if (!gConnected) {
        return;
    }
    gRcvPB.ioCompletion = NULL;
    gRcvPB.ioCRefNum = gRefNum;
    gRcvPB.csCode = TCPRcv;
    gRcvPB.tcpStream = gStream;
    gRcvPB.csParam.receive.commandTimeoutValue = 0;   /* the driver's own */
    gRcvPB.csParam.receive.rcvBuff = (Ptr)gDrainBuff;
    gRcvPB.csParam.receive.rcvBuffLen = (unsigned short)kDrainBuffLen;
    gRcvPB.csParam.receive.userDataPtr = NULL;
    if (PBControlAsync((ParmBlkPtr)&gRcvPB) == noErr) {
        gRcvInFlight = true;
    }
}

/* The reap. Called first on every pump: a result is a fact already in
   memory, and acting on a stale state before reading it is how a state
   machine driven by polling goes wrong. */
static void reap(NowPeekTable *table)
{
    OSErr err;

    if (gInFlight == kInFlightNone) {
        return;
    }
    if (gCtlPB.ioResult > 0) {
        return;                       /* still queued in the driver */
    }
    err = (OSErr)gCtlPB.ioResult;
    switch (gInFlight) {
    case kInFlightOpen:
        gInFlight = kInFlightNone;
        if (err == noErr) {
            gConnected = true;
            gHelloSent = false;
            table->channel_result = 0;
        } else {
            table->channel_result = (NowPeekI32)err;
            table->channel_state = kNowPeekChannelFailed;
            gRetryCountdown = kRetryTicks;
            /* A refused ActiveOpen leaves the stream unusable until it
               is aborted, and a stream that is never reset is a channel
               that never recovers from one unlucky dial. */
            issue_abort();
        }
        break;
    case kInFlightSend:
        gInFlight = kInFlightNone;
        if (err == noErr) {
            table->channel_sends++;
            if (!gHelloSent) {
                gHelloSent = true;
                gPingCountdown = kPingEveryTicks;
            }
            table->channel_state = kNowPeekChannelUp;
            table->channel_result = 0;
        } else {
            table->channel_result = (NowPeekI32)err;
            table->channel_state = kNowPeekChannelFailed;
            gRetryCountdown = kRetryTicks;
            issue_abort();
        }
        break;
    case kInFlightAbort:
    default:
        gInFlight = kInFlightNone;
        break;
    }
}

/* Called at NON-interrupt time, once, from the jGNE filter's first pass -
   the only such context this component has. Everything that can move
   memory or block happens HERE and nowhere else: opening the driver and
   creating the stream. */
void now_liveness_net_prepare(NowPeekTable *table, short refnum)
{
    OSErr err;

    if (table == NULL || gStreamReady || gPrepareTries >= kPrepareTries) {
        return;
    }
    ++gPrepareTries;
    table->channel_format = kNowPeekChannelFormatV1;
    if (refnum == 0) {
        table->channel_state = kNowPeekChannelNoTransport;
        gPrepareTries = kPrepareTries;    /* no driver: nothing to retry */
        return;
    }
    gRefNum = refnum;
    gCtlPB.ioCompletion = NULL;
    gCtlPB.ioCRefNum = refnum;
    gCtlPB.csCode = TCPCreate;
    gCtlPB.csParam.create.rcvBuff = (Ptr)gRcvBuff;
    gCtlPB.csParam.create.rcvBuffLen = (unsigned long)kRcvBuffLen;
    gCtlPB.csParam.create.notifyProc = NULL;
    gCtlPB.csParam.create.userDataPtr = NULL;
    /* Synchronous, and legal here for the same reason PBOpenSync above it
       is: this is an application's context at non-interrupt time.
       TCPCreate touches no network - it hands MacTCP a buffer - so it
       cannot block on anything remote. */
    err = PBControlSync((ParmBlkPtr)&gCtlPB);
    table->channel_result = (NowPeekI32)err;
    if (err != noErr) {
        /* Reported as no-transport on every failed attempt, including
           the ones that will be retried: a reader between passes must
           see the machine's current answer, not an optimistic one held
           back in case a later try does better. */
        table->channel_state = kNowPeekChannelNoTransport;
        return;
    }
    gStream = gCtlPB.tcpStream;
    gStreamReady = true;
    gInFlight = kInFlightNone;
    table->channel_state = kNowPeekChannelIdle;
}

/* Called from the Time Manager tick. INTERRUPT TIME - see the header. */
void now_liveness_net_pump(NowPeekTable *table,
                           const NowPeekLivenessEndpoint *want)
{
    if (table == NULL || !gStreamReady) {
        return;                       /* prepare() already said why */
    }
    reap(table);
    drain();
    if (gInFlight != kInFlightNone) {
        return;                       /* one call at a time, by design */
    }

    /* The application has withdrawn, or never published. Zero is an
       INSTRUCTION to be off the wire, not an old value worth retrying,
       so an open connection is closed rather than kept. */
    if (want == NULL) {
        if (gConnected) {
            issue_abort();
        }
        table->channel_state = kNowPeekChannelIdle;
        return;
    }
    /* A new epoch is a new address. Drop what is up and dial the new one
       rather than reporting liveness to a host this machine's own
       application has stopped talking to. */
    if (gConnected && want->endpoint_epoch != gDialledEpoch) {
        issue_abort();
        return;
    }
    if (!gConnected) {
        if (gRetryCountdown > 0) {
            --gRetryCountdown;
            return;
        }
        issue_open(table, want);
        return;
    }
    if (!gHelloSent) {
        issue_send(table, build_hello(table));
        return;
    }
    if (gPingCountdown > 0) {
        --gPingCountdown;
        return;
    }
    gPingCountdown = kPingEveryTicks;
    /* The id is the send count, which is monotonic for the life of the
       connection and needs no counter of its own. The host echoes it in
       `pong` and nothing here reads the echo. */
    issue_send(table, build_ping(table->channel_sends + 1));
}
