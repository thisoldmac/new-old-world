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
 * THE DEADLINE, ADDED 2026-08-17, AND WHY POLLING NEEDED ONE. The
 * decision above - no completion routines, reap `ioResult` on the next
 * tick - is still right, but it shipped with a hole: `reap()` returned
 * while `ioResult > 0` and NOTHING ever decided that had gone on too
 * long. A completion routine cannot be starved; a poll of a call the
 * driver never completes waits forever, and the pump's one-call-at-a-time
 * guard sits ABOVE every other branch, so a single stuck call took out
 * the pings, the redial, the epoch change, and even the application's
 * instruction to get off the wire. On 2026-08-17 an attended metal
 * session produced zero resident frames for its whole length and the
 * PowerBook needed a reboot: the guest half of Continuity has no other
 * lane, so this channel being quietly stuck is the entire feature being
 * dead with nothing said about it.
 *
 * So `wedge_watch` gives every in-flight call a deadline set just outside
 * the transport timeout the call already carries, and a call that misses
 * it is treated as a stuck DRIVER rather than a slow network. The
 * recovery is deliberately the smallest one that can work: an abort of
 * the stream, issued on a param block of its own, and then patience. The
 * stream is never released and recreated - that is the teardown that has
 * cost this project real machines, it needs a context this component only
 * has at boot, and it buys nothing, because every buffer here is a static
 * that lives for the boot anyway. The channel reports `wedged` while it
 * waits, counts what it saw, and dials again within ~55 s of the host
 * vanishing. Never a reboot; that is the promise.
 *
 * WHAT IT DOES NOT DO. It never reads a reply for meaning. The host
 * answers `pong` and the contract permits nothing else on this channel,
 * so the receive path exists only to keep MacTCP's buffer from filling.
 * A resident that parsed replies would be a second command lane, and the
 * host refuses one by name.
 *
 * THE SECOND THING THIS CHANNEL CARRIES, AND WHY IT IS HERE
 * ---------------------------------------------------------
 * `now_liveness_net_send_drag` puts one drag-begin identity on this same
 * connection, and it is the only thing on this wire that is not
 * liveness. It is here because of WHO CAN SPEAK DURING A DRAG: the
 * identity of a dragged icon is read by the tracking handler inside the
 * Finder's own drag loop, and the PowerPC application that would
 * otherwise publish it gets no task time at all while that loop runs -
 * measured 2026-08-16, the drag-sourced generation reached the host 462
 * ticks after the drag began and 14 ticks after it ENDED. A fact known
 * inside the loop has to leave through something that is also inside the
 * loop, and this channel's globals are the resident's own system-heap
 * storage, reachable from every context.
 *
 * FOUR RULES IT KEEPS, because the caller is somebody else's drag loop:
 *
 *   - IT IS TASK TIME, NOT INTERRUPT TIME. The pump above is the
 *     interrupt-time half and this is not called from it, ever. A drag
 *     frame built from an interrupt would be the exact context error six
 *     PowerBook wedges were bought with.
 *   - IT NEVER BLOCKS THE FINDER. One PBControlAsync with a nil
 *     completion and no wait, no retry, and no second attempt. The
 *     handler returns to the Drag Manager having spent a queue call.
 *   - IT HAS ITS OWN PARAM BLOCK. `gCtlPB` belongs to the pump's
 *     one-call-at-a-time state machine, and an interrupt landing on a
 *     block a task-time caller is filling in is a corruption rather than
 *     a race to argue about. `gDragPB` is written by this function only.
 *     Two TCPSends outstanding on one stream is ordinary MacTCP: the
 *     driver keeps a per-stream queue and transmits them in the order
 *     they were issued, so neither frame can be cut into the other.
 *   - NOTHING IS QUEUED. A drag whose frame cannot go out now is
 *     COUNTED and dropped. A queue here would be a resident holding
 *     somebody's file identity for an unbounded time, and the host has a
 *     fallback for a drag it was never told about; it has none for a
 *     drag it is told about a minute late.
 */

#include <Devices.h>
#include <MacTCP.h>
#include <MacTypes.h>

#include "continuity_udp.h"
#include "peek_table.h"
#include "wire_limits.h"

/* The resident's own version string. It is NOT the application's and
   must not borrow it: the two halves are separately deployable, and a
   channel reporting the version of a binary it is not is worse than one
   reporting nothing. resident_version.h is also what the shared table
   reads, so the resident cannot report two different versions through its
   two faces again. Display only, per the contract. */

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
    /* One drag-begin frame. The variable parts are a 31-byte HFS name,
       which can double under JSON escaping, and two four-character
       codes; everything else is constant text and five small integers.
       Sized with room rather than to the byte, because a builder that
       overflows here sends NOTHING and the drag is lost. */
    kDragBuffLen = 320,

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
    kPrepareTries = 5,

    /* THE DEADLINES. Everything below is in units of the vehicle's 5 s
       tick, and every one of them exists because until 2026-08-17 there
       were none: `reap()` returned while `ioResult > 0` forever, so one
       MacTCP call the driver never completed left this channel returning
       at its one-call-at-a-time guard for the rest of the boot. An
       attended metal session produced ZERO resident frames because of it
       and the machine needed a reboot (F2 defect A).

       A deadline here is NOT a second transport timeout. Every call this
       channel issues already carries `ulpTimeoutValue = 30` with
       `ulpTimeoutAction = 1` (abort), so a call MacTCP is honestly
       working on completes within 30 s or is abandoned by the driver
       itself. These numbers are therefore not a policy about how long a
       network may take - the transport owns that - they are the point
       past which the DRIVER'S OWN timeout has demonstrably not fired, and
       what is being detected is a stuck driver rather than a slow peer.
       That is why they are set just outside the transport's own budget
       and not tuned: tightening one would start aborting healthy calls,
       and healthy calls are what carry liveness. */

    /* Eight ticks, ~40 s, for an open or a send: the transport's own 30 s
       budget, plus one whole tick because the poll granularity IS a tick,
       plus one more so a tick that lands a hair early can never convict a
       call the driver was about to complete. */
    kInFlightWedgeTicks = 8,
    /* Four ticks, ~20 s, for an abort. TCPAbort spends no time waiting on
       a remote party - it puts an RST on the wire and completes locally -
       so it has no 30 s budget to be given the benefit of. It gets four
       polls of slack instead, and it needs its own number because the
       abort is the RECOVERY: reap()'s failure branches issue it, so an
       abort that latches is the failure path failing, and that must not
       be the slowest thing here to notice. */
    kAbortWedgeTicks = 4,
    /* Six ticks, ~30 s, for a receive left in flight after the connection
       has gone. Time in flight is NOT evidence against a receive while a
       connection is up - waiting for bytes is its whole job, and its
       commandTimeoutValue is deliberately 0 (infinite) - so this clock
       only runs once `gConnected` is false. Thirty seconds after that is
       long past when an abort should have completed it. */
    kRcvSettleTicks = 6,
    /* Ticks before dialling again once a wedge has been cleared. TWO,
       ~10 s, rather than the twelve a refused dial takes: a refused dial
       means the host is very likely not up and backing off is politeness,
       while a cleared wedge means this machine has ALREADY been off the
       wire for the ~40 s the deadline cost, and the overwhelmingly likely
       cause - a host process that died and came back - is one that is
       listening again by now. The bound this buys is the one that
       matters, and it is what the fix promises: from a host vanishing to
       this resident dialling again is at most ~55 s (40 s deadline + one
       tick to abort + 10 s backoff), and never a reboot. */
    kRedialTicks = 2,
    /* If the abort does not free the stuck call, try again every twelve
       ticks (~60 s) rather than every tick. The stream is not released
       and recreated: TCPRelease against a driver that still owns a param
       block is the teardown this project has been bloodied by before, and
       it buys nothing a repeated abort does not - the buffers here are
       statics that live for the boot, so a stream nobody can free costs
       no memory, only patience. The channel stays honestly `wedged` and
       recovers the moment the driver ever completes. */
    kWedgeAbortRetryTicks = 12
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

/* The wedge watch's own state.
   ------------------------------------------------------------------
   `gWedgeAbortPB` is a THIRD param block and that is the whole point of
   it: a wedge is by definition a call the driver still owns, so the
   recovery cannot be issued on `gCtlPB` - filling in a block MacTCP is
   holding is a corruption rather than a race to argue about, which is the
   same reason `gDragPB` exists. Two calls outstanding on one stream is
   ordinary MacTCP, and an abort is precisely the call that makes the
   driver complete the other one. */
static TCPiopb gWedgeAbortPB;
static Boolean gWedgeAbortInFlight;
static short gWedgeAbortCountdown;
static short gInFlightTicks;          /* ticks the control call has waited */
static short gRcvIdleTicks;           /* ticks a receive has outlived its
                                         connection */
static Boolean gWedged;               /* a deadline has been exceeded and
                                         the driver has not yet handed the
                                         param block back */
static Boolean gRedialPending;        /* the next dial follows a recovery */
/* The drain saw the peer go. Set at the receive's completion and acted on
   by the pump, because the abort belongs to the one-call-at-a-time state
   machine and the drain is not part of it. */
static Boolean gPeerGone;
static NowPeekI32 gPeerGoneResult;
static short gWedgeStreak;            /* consecutive wedges without an
                                         intervening healthy connection */

/* The drag-begin send's own everything. Written from TASK time in a
   foreign application and never touched by the interrupt-time pump - see
   the header's fourth rule. */
static TCPiopb gDragPB;
static wdsEntry gDragWDS[2];
static Boolean gDragInFlight;

static unsigned char gRcvBuff[kRcvBuffLen];
static unsigned char gSendBuff[kSendBuffLen];
static unsigned char gDrainBuff[kDrainBuffLen];
static unsigned char gDragBuff[kDragBuffLen];

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

static void begin_frame_in(Build *b, unsigned char *buf, unsigned long cap)
{
    b->buf = buf;
    b->len = NOW_WIRE_FRAME_HEADER_BYTES;
    b->cap = cap;
    b->overflowed = false;
}

static void begin_frame(Build *b)
{
    begin_frame_in(b, gSendBuff, kSendBuffLen);
}

/* A signed integer, because a vRefNum is one and always negative for a
   mounted volume. Written as a sign and the unsigned magnitude rather
   than by negating: -2147483648 has no positive counterpart and a
   formatter that assumes it does is wrong exactly once, silently. */
static void put_i32(Build *b, NowPeekI32 v)
{
    unsigned long magnitude;

    if (v < 0) {
        put_byte(b, '-');
        magnitude = (unsigned long)(-(long)(v + 1)) + 1UL;
    } else {
        magnitude = (unsigned long)v;
    }
    put_u32(b, (NowPeekU32)magnitude);
}

/* Four characters out of an OSType, JSON-escaped by the same rules the
   machine name uses. A code is not a string the Toolbox NUL-terminates,
   so all four bytes go out including embedded spaces - 'PDF ' is a real
   type and trimming it would name a different one. A NUL byte becomes a
   space rather than ending the code early: an OSType with one in it is
   already malformed, and truncating would hand the host a shorter code
   that means something else. */
static void put_ostype(Build *b, NowPeekU32 code)
{
    int i;

    for (i = 3; i >= 0; --i) {
        unsigned char c = (unsigned char)((code >> (i * 8)) & 0xFF);

        if (c == '"' || c == '\\') {
            put_byte(b, '\\');
            put_byte(b, c);
        } else if (c < 0x20) {
            put_byte(b, ' ');
        } else {
            put_byte(b, c);
        }
    }
}

/* An HFS name out of the drag observer's fixed-width Pascal copy. Same
   escaping as put_pascal_json, which it cannot simply call because that
   one takes the field width as the cap and this field is 64 bytes wide
   while the contract's name is 31 - a longer name is refused rather than
   truncated, because half a file name is a different file. */
static void put_drag_name(Build *b, const unsigned char *p)
{
    unsigned long n = p[0];
    unsigned long i;

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
                 NOW_RESIDENT_VERSION_STRING "\",\"name\":\"");
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
        gInFlightTicks = 0;
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
        gInFlightTicks = 0;
    }
}

/* The wedge recovery, on its own param block. Issued when a control call
   has outlived the transport's own timeout, which means the driver still
   owns `gCtlPB` and nothing may be written into it. An abort is legal
   here for the same reason every other call in this file is - it queues
   and returns - and it is the one call that makes MacTCP complete the
   pending work on this stream, which is what hands `gCtlPB` and `gRcvPB`
   back so the ordinary reap can run again. */
static void issue_wedge_abort(void)
{
    if (gWedgeAbortInFlight) {
        return;
    }
    gWedgeAbortPB.ioCompletion = NULL;
    gWedgeAbortPB.ioCRefNum = gRefNum;
    gWedgeAbortPB.csCode = TCPAbort;
    gWedgeAbortPB.tcpStream = gStream;
    gWedgeAbortPB.csParam.abort.userDataPtr = NULL;
    /* Off the wire from this instant, whatever the driver does with the
       call. The drag path reads these two words and must count its frames
       as unconnected rather than hand them to a stream nobody can use. */
    gConnected = false;
    gHelloSent = false;
    gWedgeAbortCountdown = kWedgeAbortRetryTicks;
    if (PBControlAsync((ParmBlkPtr)&gWedgeAbortPB) == noErr) {
        gWedgeAbortInFlight = true;
    }
}

static void issue_open(NowPeekTable *table,
                       const NowPeekLivenessEndpoint *want)
{
    int i;

    /* A stream with a receive still pending REFUSES an ActiveOpen, and a
       dial refused for that reason is not a host that is down: it is this
       channel racing its own last connection. Dialling anyway is how the
       silent-from-boot failure presented as an endless 60-second retry
       loop that could never succeed, so the receive is settled first -
       the wedge watch is already aborting the stream on its behalf. */
    if (gRcvInFlight) {
        return;
    }
    if (gRedialPending) {
        gRedialPending = false;
        table->channel_redials++;
    }
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
        gInFlightTicks = 0;
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
        /* ANY ERROR AT ALL: the connection is gone or going, and THIS is
           where the machine learns it first.
           ------------------------------------------------------------
           This used to say the control path would find out the same way
           on its next send, and that was measured wrong on 2026-08-17:
           a host process killed ungracefully was answering the
           application again 2 s later, and the resident took 179.9 s to
           follow - three times, to a tick. MacTCP will accept send after
           send into a connection whose peer has gone and complete every
           one of them, so the send path is nearly blind to a dead peer.
           The receive is not: the peer's FIN completes this pending
           TCPRcv within a second, and the error it carries is the fact
           the whole channel was waiting three minutes to discover.
           So it is not discarded any more - it is handed to the pump,
           which owns what to do about it. */
        if (gRcvPB.ioResult != noErr) {
            if (gConnected) {
                gPeerGone = true;
                gPeerGoneResult = (NowPeekI32)gRcvPB.ioResult;
            }
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
    if (gWedged) {
        /* The driver has handed back a call we had already given up on.
           This is the ONLY positive evidence that a wedge cleared, and it
           is counted separately from the wedge itself because "we noticed"
           and "we got the machine back" are different facts and a reader
           with one number cannot tell them apart. The dial that follows
           is short-backed-off on the first wedge of a run and politely
           backed off after that, so a channel wedging repeatedly does not
           become a channel dialling repeatedly. */
        gWedged = false;
        table->channel_wedge_reaps++;
        gRedialPending = true;
        gRetryCountdown = (gWedgeStreak > 1) ? kRetryTicks : kRedialTicks;
        /* Whatever the call was, it belonged to a connection this channel
           has already abandoned, so its result decides nothing. Fall
           through to clear the state machine and let the pump dial. */
        gInFlight = kInFlightNone;
        gInFlightTicks = 0;
        table->channel_result = (NowPeekI32)err;
        return;
    }
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
                /* A host that has heard this machine's hello is a healthy
                   connection, which is what the streak counts the absence
                   of: it exists so repeated wedges back off and a single
                   one does not. */
                gWedgeStreak = 0;
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

static void drag_reap(void);

/* THE WEDGE WATCH. Interrupt time, and bounded to arithmetic on this
   component's own globals plus at most one queued abort.
   ------------------------------------------------------------------
   This is the deadline the file did not have. It answers exactly one
   question - has a call outlived the timeout the transport itself was
   given - and it answers it by counting the ticks the pump has already
   spent returning at its one-call-at-a-time guard, which costs nothing
   and needs no clock.
   What it does NOT do is forget the call. The driver still owns the param
   block; abandoning it and reusing the block is the corruption this whole
   component is written to avoid. It aborts the STREAM instead, on a param
   block of its own, and waits for MacTCP to hand the stuck one back. */
static void wedge_watch(NowPeekTable *table)
{
    short deadline;

    /* Our own abort, reaped the same way everything else here is. */
    if (gWedgeAbortInFlight && gWedgeAbortPB.ioResult <= 0) {
        gWedgeAbortInFlight = false;
    }

    if (gInFlight != kInFlightNone) {
        if (gInFlightTicks < 32767) {
            ++gInFlightTicks;
        }
        table->channel_wedge_ticks = (NowPeekU32)gInFlightTicks;
        deadline = (gInFlight == kInFlightAbort) ? kAbortWedgeTicks
                                                 : kInFlightWedgeTicks;
        if (!gWedged && gInFlightTicks >= deadline) {
            gWedged = true;
            ++gWedgeStreak;
            table->channel_wedges++;
            table->channel_wedge_op = (NowPeekU32)gInFlight;
            table->channel_state = kNowPeekChannelWedged;
            gWedgeAbortCountdown = 0;
        }
    } else {
        gInFlightTicks = 0;
        table->channel_wedge_ticks = 0;
    }

    /* A receive that has outlived its connection. Its clock only runs
       while the channel is down, because a receive waiting for bytes on a
       live connection is a receive doing its job. It is a wedge in its own
       right and not a cosmetic one: MacTCP refuses an ActiveOpen while it
       is pending, so this is the state that presents as a channel dialling
       forever and never connecting. */
    if (!gConnected && gRcvInFlight) {
        if (gRcvIdleTicks < 32767) {
            ++gRcvIdleTicks;
        }
        if (!gWedged && gRcvIdleTicks >= kRcvSettleTicks) {
            gWedged = true;
            ++gWedgeStreak;
            table->channel_wedges++;
            table->channel_wedge_op = (NowPeekU32)kNowPeekChannelOpReceive;
            table->channel_state = kNowPeekChannelWedged;
            gWedgeAbortCountdown = 0;
        }
    } else {
        gRcvIdleTicks = 0;
    }

    if (!gWedged) {
        return;
    }
    /* A receive freed while nothing else was stuck IS the recovery: there
       is no control call for the ordinary reap to hand back, so the wedge
       is cleared here instead. */
    if (gInFlight == kInFlightNone && !gRcvInFlight) {
        gWedged = false;
        table->channel_wedge_reaps++;
        gRedialPending = true;
        gRetryCountdown = (gWedgeStreak > 1) ? kRetryTicks : kRedialTicks;
        return;
    }
    if (gWedgeAbortCountdown > 0) {
        --gWedgeAbortCountdown;
        return;
    }
    issue_wedge_abort();
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
    /* Written-ness, declared on the first attempt: a reader has to be
       able to tell a resident that keeps this account from one built
       before the account existed, and a zeroed tail cannot say which. */
    table->channel_wedge_format = (NowPeekU32)kNowPeekChannelWedgeFormatV1;
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
    gInFlightTicks = 0;
    gRcvIdleTicks = 0;
    gWedged = false;
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
    wedge_watch(table);
    if (!gConnected) {
        /* Our own drag frame, reaped from here rather than only from the
           next drag. It is read-only on a word the task-time sender owns,
           and it is safe BECAUSE of the guard above it: `send_drag`
           returns before touching anything while `gConnected` is false, so
           there is no task-time writer to race while this runs. A drag
           frame outliving its connection is not itself a wedge - nothing
           waits on it - but it holds a param block pointed at a stream the
           recovery is aborting, and a stale one must not be left to meet a
           reconnected channel as `drag_send_busy`. */
        drag_reap();
    }
    if (gInFlight != kInFlightNone) {
        return;                       /* one call at a time, by design */
    }

    /* THE DRAIN SAW THE PEER GO. Acted on here rather than there, because
       the abort belongs to the one-call-at-a-time state machine above and
       a drain that issued its own would be a second writer of `gCtlPB`.
       The short backoff is deliberate and cannot spin: a host process
       that closed its socket is very often one that is restarting, and a
       dial with nobody listening FAILS, which takes the ordinary 60 s
       backoff. So this trades a fast return when the host is coming back
       for nothing at all when it is not. */
    if (gPeerGone) {
        gPeerGone = false;
        table->channel_result = gPeerGoneResult;
        table->channel_state = kNowPeekChannelFailed;
        gRetryCountdown = kRedialTicks;
        issue_abort();
        return;
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
        /* A NEW EPOCH ENDS THE BACKOFF, and this is the difference between
           a resident that comes back in seconds and one that comes back in
           three minutes.
           ------------------------------------------------------------
           The backoff exists to be polite to a host that is not up: a
           Macintosh booted before the Mac it talks to is the normal case,
           and hammering it would be rude and useless. But an endpoint
           epoch only moves when this machine's OWN application has just
           completed a hello with a host - so a new epoch is positive
           evidence, from inside this machine, that somebody is listening
           on that address RIGHT NOW. Waiting out a politeness timer
           against a host we can see is up is not politeness, it is delay.
           Measured 2026-08-17 on the emulator: a host process killed
           ungracefully was answering the application again 2 s later, and
           the resident took 175 s to follow because it sat out this
           countdown. It is not self-perpetuating - `issue_open` records
           the epoch it dialled, so a dial that fails backs off normally
           and a stale epoch never clears the timer twice. */
        if (gRetryCountdown > 0 && want->endpoint_epoch != gDialledEpoch) {
            gRetryCountdown = 0;
        }
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

/* ---------------------------------------------------------------- */
/* The drag-begin frame. TASK TIME, in the dragging application.      */
/* ---------------------------------------------------------------- */

/* NO SIZES, NO DATES, NO FOLDERNESS, and that is the design rather than
   a gap. Every one of those needs the File Manager, and this runs inside
   a foreign application's drag loop where the resident's charter permits
   no such call - `now_ext_dragobs.c` says it in its own header and the
   HFSFlavor the Drag Manager already handed us needs none of them. The
   host is told what a live DragRef knows: which file, by the triple the
   File Manager itself uses, plus its type and creator. The rest arrives
   with the application's own publish of the same gesture and again at
   grab redemption, both of which happen long before a drop. */
static unsigned long build_drag_begin(NowPeekU32 epoch, NowPeekU32 seq,
                                      NowPeekU32 ticks, NowPeekU32 file_type,
                                      NowPeekU32 creator, NowPeekI32 vref,
                                      NowPeekU32 parid,
                                      const unsigned char *name)
{
    Build b;

    begin_frame_in(&b, gDragBuff, kDragBuffLen);
    put_cstr(&b, "{\"type\":\"continuity.dragBegin\",\"version\":");
    put_u32(&b, (NowPeekU32)NOW_CONTINUITY_VERSION);
    put_cstr(&b, ",\"epoch\":");
    put_u32(&b, epoch);
    put_cstr(&b, ",\"dragSeq\":");
    put_u32(&b, seq);
    put_cstr(&b, ",\"ticks\":");
    put_u32(&b, ticks);
    put_cstr(&b, ",\"item\":{\"name\":\"");
    put_drag_name(&b, name);
    put_cstr(&b, "\",\"volumeRef\":");
    put_i32(&b, vref);
    put_cstr(&b, ",\"dirID\":");
    put_u32(&b, parid);
    put_cstr(&b, ",\"fileType\":\"");
    put_ostype(&b, file_type);
    put_cstr(&b, "\",\"creator\":\"");
    put_ostype(&b, creator);
    put_cstr(&b, "\"}}");
    return finish_frame(&b);
}

/* Reap our own previous frame, if the driver has finished with it. There
   is no state machine here on purpose: the only thing this needs to know
   is whether the param block is free to fill in again. A failed send is
   not retried and not reported to the channel state - the pump owns that
   word, and a drag frame failing says nothing about liveness. */
static void drag_reap(void)
{
    if (!gDragInFlight) {
        return;
    }
    if (gDragPB.ioResult > 0) {
        return;                       /* still queued in the driver */
    }
    gDragInFlight = false;
}

int now_liveness_net_send_drag(NowPeekTable *table, NowPeekU32 epoch,
                               NowPeekU32 seq, NowPeekU32 ticks,
                               NowPeekU32 file_type, NowPeekU32 creator,
                               NowPeekI32 vref, NowPeekU32 parid,
                               const unsigned char *name)
{
    unsigned long len;

    if (table == NULL || name == NULL || seq == 0) {
        return 0;
    }
    table->drag_send_format = (NowPeekU32)kNowPeekDragSendFormatV1;
    if (!gStreamReady || !gConnected || !gHelloSent) {
        /* No connection, or one the host has not been introduced to yet.
           Counted rather than queued: a host that has never heard this
           machine's hello cannot attach a drag to it either. */
        table->drag_send_unconnected++;
        return 0;
    }
    drag_reap();
    if (gDragInFlight) {
        /* Our own previous drag frame is still with the driver. Two
           drags inside one send is not a case worth a queue - the second
           one's cross is seconds away and the fallback lane still has
           it - so it is counted and dropped. */
        table->drag_send_busy++;
        return 0;
    }
    len = build_drag_begin(epoch, seq, ticks, file_type, creator, vref,
                           parid, name);
    if (len == 0) {
        table->drag_send_dropped++;   /* the builder overflowed */
        return 0;
    }
    gDragWDS[0].length = (unsigned short)len;
    gDragWDS[0].ptr = (Ptr)gDragBuff;
    gDragWDS[1].length = 0;
    gDragWDS[1].ptr = NULL;

    gDragPB.ioCompletion = NULL;
    gDragPB.ioCRefNum = gRefNum;
    gDragPB.csCode = TCPSend;
    gDragPB.tcpStream = gStream;
    /* Bounded, and it aborts rather than hangs - the same pair the pump
       uses, for a reason that bites harder here: this call is made with
       the Finder's drag loop waiting on it. */
    gDragPB.csParam.send.ulpTimeoutValue = 30;
    gDragPB.csParam.send.ulpTimeoutAction = 1;
    gDragPB.csParam.send.validityFlags = timeoutValue | timeoutAction;
    gDragPB.csParam.send.pushFlag = true;
    gDragPB.csParam.send.urgentFlag = false;
    gDragPB.csParam.send.wdsPtr = (Ptr)gDragWDS;
    gDragPB.csParam.send.sendFree = 0;
    gDragPB.csParam.send.sendLength = 0;
    gDragPB.csParam.send.userDataPtr = NULL;
    if (PBControlAsync((ParmBlkPtr)&gDragPB) != noErr) {
        table->drag_send_dropped++;
        return 0;
    }
    gDragInFlight = true;
    table->drag_send_sends++;
    table->drag_send_last_seq = seq;
    return 1;
}
