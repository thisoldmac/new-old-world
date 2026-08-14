/* Continuity's PowerPC application half. The OT notifier does bounded,
   preallocated decode and one shared-table publish; policy, UI and JSON stay
   in task time. UDP cannot arm this module: only now_continuity_arm, reached
   from the authenticated TCP control stream, establishes its token. */
#include "continuity_intake.h"

#include <Carbon.h>
#include <OpenTransport.h>
#include <OpenTptInternet.h>

#include <string.h>

#include "continuity_report_logic.h"
#include "continuity_cursor.h"
#include "continuity_service.h"
#include "arm_target.h"
#include "nowlog.h"
#include "now_continuity_keyboard_logic.h"
#include "now_continuity_wire.h"
#include "ot_carbon.h"
#include "peek.h"

enum { kContinuityNotifierDrainMax = 8 };

static EndpointRef gEndpoint = kOTInvalidEndpointRef;
static OTNotifyUPP gNotifier;
static unsigned short gRequestedPort;
static unsigned short gBoundPort;
static volatile NowCU32 gNonceHi;
static volatile NowCU32 gNonceLo;
static volatile NowCU32 gEpoch;
static int gFastPump;
static volatile NowCU32 gMalformed;
static volatile NowCU32 gRejected;
static volatile Boolean gAckPending;
static volatile NowCU32 gAckPublishSeq;
static volatile NowCU32 gAckSends;
static volatile NowCU32 gAckFlowStops;
static volatile NowCU32 gAckRetries;
static volatile NowCU32 gAckErrors;
static volatile NowCU32 gAckGoData;
static Boolean gAckRetrying;
static volatile long gPendingReplyID;
static volatile NowCU32 gPendingControlSeq;
static NowCU32 gLastReportedStatusSeq;
static NowCU32 gLastTerminalEpoch;
static NowCU32 gLastTerminalReason;
static int gHaveReportedTerminal;

static TUnitData gReceive;
static InetAddress gFrom;
static NowCU8 gReceiveBytes[64];
static TUnitData gSend;
static InetAddress gReplyTo;
static InetAddress gSendReplyTo;
static NowCU8 gAckBytes[NOW_CONTINUITY_ACK_BYTES];
/* Published by the task-time arm before gEpoch becomes nonzero. The OT
   notifier must not call cell()/now_peek_table(): that path validates the
   current Process Manager identity, renews the writer lease, and logs. At
   packet rate it re-entered all three from notifier context and wedged PMU
   during a simultaneous Cursor Device call. The resident table is stable for
   this application's lifetime, so the notifier needs only this cached cell. */
static NowPeekContinuityCell * volatile gNotifierCell;

static NowPeekContinuityCell *cell(void)
{
    NowPeekTable *table = (NowPeekTable *)now_peek_table();
    if (table == NULL
        || table->length < (NowPeekU32)(offsetof(NowPeekTable, continuity)
                                        + sizeof(NowPeekContinuityCell))
        || table->continuity_format != NOW_CONTINUITY_FORMAT_CURRENT
        || !(table->caps & kNowPeekTableCapContinuity))
        return NULL;
    return &table->continuity;
}

static void bump_nonzero(volatile NowPeekU32 *value)
{
    (*value)++;
    if (*value == 0)
        *value = 1;
}

static int prepare_ack(NowPeekContinuityCell *shared)
{
    NowContinuityAckPacket ack;
    NowPeekU32 before;
    int tries;
    int stable = 0;

    memset(&ack, 0, sizeof ack);
    ack.nonce_hi = gNonceHi;
    ack.nonce_lo = gNonceLo;
    ack.epoch = gEpoch;
    for (tries = 0; tries < 2; ++tries) {
        before = shared->status_seq;
        if (before & 1)
            continue;
        ack.position_seq = shared->applied_position_seq;
        ack.button_generation = shared->applied_button_generation;
        ack.arrival_ticks = shared->last_arrival_ticks;
        ack.apply_ticks = shared->apply_ticks;
        ack.accepted_hz = (NowCU16)shared->accepted_hz;
        ack.exit_reason = (NowCU16)shared->exit_reason;
        if (ack.exit_reason > NOW_CONTINUITY_EXIT_DISARMED)
            ack.exit_reason = NOW_CONTINUITY_EXIT_DISARMED;
        if (shared->state == kNowPeekContinuityStateArmed)
            ack.state = NOW_CONTINUITY_ACK_ARMED;
        else if (shared->state == kNowPeekContinuityStateActive)
            ack.state = NOW_CONTINUITY_ACK_ACTIVE;
        else
            ack.state = NOW_CONTINUITY_ACK_INACTIVE;
        if (before == shared->status_seq) {
            stable = 1;
            break;
        }
    }
    if (!stable)
        return 0;
    ack.rejected_packets = gRejected + gMalformed;
    now_continuity_encode_ack(&ack, gAckBytes);
    gSend.addr.buf = (UInt8 *)&gSendReplyTo;
    gSend.addr.len = sizeof gSendReplyTo;
    gSend.opt.buf = NULL;
    gSend.opt.len = 0;
    gSend.udata.buf = (UInt8 *)gAckBytes;
    gSend.udata.len = NOW_CONTINUITY_ACK_BYTES;
    return 1;
}

/* One task-time send attempt. OTSndUData is deliberately absent from the OT
   notifier: a flow-controlled call there twice stopped the cooperative OS,
   including an unrelated anchor process. The ordinary and nested event-loop
   pumps call this again, so pressure costs one bounded attempt per pass. */
static void try_send_ack(NowPeekContinuityCell *shared)
{
    OSStatus err;
    NowCU32 publish_seq;

    if (!gAckPending || shared == NULL || gEpoch == 0
        || gEndpoint == kOTInvalidEndpointRef) {
        gAckPending = false;
        return;
    }
    publish_seq = gAckPublishSeq;
    if (publish_seq & 1)
        return;
    gSendReplyTo = gReplyTo;
    if (publish_seq != gAckPublishSeq)
        return;
    if (gAckRetrying)
        gAckRetries++;
    /* Rebuild on a retry: absolute Continuity state coalesces, so the newest
       applied point is more useful than preserving an ACK made stale while
       Open Transport was flow-controlled. */
    if (!prepare_ack(shared))
        return;
    err = gNowOT.sndUData(gEndpoint, &gSend);
    if (err == noErr) {
        if (publish_seq == gAckPublishSeq) {
            gAckPending = false;
            gAckRetrying = false;
        }
        gAckSends++;
    } else if (err == kOTFlowErr || err == kOTNoDataErr) {
        if (publish_seq == gAckPublishSeq) {
            gAckPending = true;
            gAckRetrying = true;
        }
        gAckFlowStops++;
    } else {
        if (publish_seq == gAckPublishSeq) {
            gAckPending = false;
            gAckRetrying = false;
        }
        gAckErrors++;
    }
}

static void publish_ack_request(void)
{
    gAckPublishSeq++;                 /* odd: notifier writes the address */
    gReplyTo = gFrom;
    gAckPending = true;
    gAckRetrying = false;
    gAckPublishSeq++;                 /* even: task time may snapshot it */
}

static void accept_datagram(const NowContinuityStatePacket *packet)
{
    NowPeekContinuityCell *shared = gNotifierCell;

    if (shared == NULL || packet->nonce_hi != gNonceHi
        || packet->nonce_lo != gNonceLo || packet->epoch != gEpoch) {
        gRejected++;
        return;
    }
    shared->packet_epoch = packet->epoch;
    shared->position_seq = packet->position_seq;
    shared->want_h = packet->h;
    shared->want_v = packet->v;
    shared->button_generation = packet->button_generation;
    shared->flags = packet->flags;
    shared->previous_button_generation = packet->previous_button_generation;
    shared->previous_button_flags = packet->previous_button_flags;
    shared->arrival_ticks = (NowPeekU32)TickCount();
    bump_nonzero(&shared->packet_seq);       /* publish last */
    publish_ack_request();
}

static void drain_endpoint(void)
{
    int drained;

    for (drained = 0; drained < kContinuityNotifierDrainMax; ++drained) {
        OTFlags flags = 0;
        NowContinuityStatePacket packet;
        OSStatus err;

        gReceive.addr.buf = (UInt8 *)&gFrom;
        gReceive.addr.maxlen = sizeof gFrom;
        gReceive.addr.len = 0;
        gReceive.opt.buf = NULL;
        gReceive.opt.maxlen = 0;
        gReceive.opt.len = 0;
        gReceive.udata.buf = (UInt8 *)gReceiveBytes;
        gReceive.udata.maxlen = sizeof gReceiveBytes;
        gReceive.udata.len = 0;
        err = gNowOT.rcvUData(gEndpoint, &gReceive, &flags);
        if (err != noErr)
            return;
        if (now_continuity_decode_state(
                gReceiveBytes, (NowCU32)gReceive.udata.len, &packet)
                != kNowContinuityWireOK) {
            gMalformed++;
            continue;
        }
        accept_datagram(&packet);
    }
}

static pascal void continuity_notifier(void *context, OTEventCode code,
                                       OTResult result, void *cookie)
{
    (void)context;
    (void)result;
    (void)cookie;
    if (code == T_DATA)
        drain_endpoint();
    else if (code == T_GODATA)
        gAckGoData++;
    else if (code == T_UDERR)
        (void)gNowOT.rcvUDErr(gEndpoint, NULL);
}

static void close_udp(const char *reason)
{
    OSStatus unbind_err = noErr;
    OSStatus close_err = noErr;

    if (gEndpoint != kOTInvalidEndpointRef) {
        now_log(kLogWarn, "mirror", "UDP close begin: %s",
                reason != NULL ? reason : "unspecified");
        now_log_flush();
        gNowOT.removeNotifier(gEndpoint);
        unbind_err = gNowOT.unbind(gEndpoint);
        close_err = gNowOT.closeProvider(gEndpoint);
        gEndpoint = kOTInvalidEndpointRef;
        now_log(unbind_err == noErr && close_err == noErr
                    ? kLogInfo : kLogWarn,
                "mirror", "UDP close end: unbind=%ld close=%ld",
                (long)unbind_err, (long)close_err);
    }
    gAckPending = false;
    gAckRetrying = false;
    if (gNotifier != NULL) {
        DisposeOTNotifyUPP(gNotifier);
        gNotifier = NULL;
    }
    gRequestedPort = 0;
    gBoundPort = 0;
}

static int open_udp(unsigned short port)
{
    OTConfigurationRef config;
    TEndpointInfo info;
    TBind request;
    TBind result;
    InetAddress bind_address;
    InetAddress bound_address;
    OSStatus err;

    if (gEndpoint != kOTInvalidEndpointRef && gRequestedPort == port
        && gBoundPort != 0)
        return 1;
    close_udp("port changed");
    if (now_ot_ensure_inited() != noErr) {
        now_log(kLogError, "mirror", "UDP open: OT unavailable");
        return 0;
    }
    config = OTCreateConfiguration("udp");
    if (config == NULL
        || config == (OTConfigurationRef)kOTInvalidConfigurationPtr) {
        now_log(kLogError, "mirror", "UDP open: no configuration");
        return 0;
    }
    gEndpoint = gNowOT.openEndpoint(config, 0, &info, &err, gNowOTContext);
    if (err != noErr || gEndpoint == kOTInvalidEndpointRef) {
        gEndpoint = kOTInvalidEndpointRef;
        now_log(kLogError, "mirror", "UDP open endpoint failed: %ld",
                (long)err);
        return 0;
    }
    gNotifier = NewOTNotifyUPP(continuity_notifier);
    if (gNotifier == NULL
        || gNowOT.installNotifier(gEndpoint, gNotifier, NULL) != noErr
        || gNowOT.setAsynchronous(gEndpoint) != noErr) {
        close_udp("notifier setup failed");
        return 0;
    }
    OTInitInetAddress(&bind_address, port, kOTAnyInetAddress);
    request.addr.buf = (UInt8 *)&bind_address;
    request.addr.len = sizeof bind_address;
    request.addr.maxlen = sizeof bind_address;
    request.qlen = 0;
    result.addr.buf = (UInt8 *)&bound_address;
    result.addr.len = 0;
    result.addr.maxlen = sizeof bound_address;
    result.qlen = 0;
    memset(&bound_address, 0, sizeof bound_address);
    if (gNowOT.bind(gEndpoint, &request, &result) != noErr) {
        close_udp("bind failed");
        return 0;
    }
    /* XTI is allowed to return a different address than the one requested.
       Reporting the requested TCP preference as the UDP destination made a
       successful alternate bind indistinguishable from a dead listener: the
       host sent to the wrong port while both halves said "armed". */
    if (result.addr.len < (OTByteCount)offsetof(InetAddress, fHost)
        || bound_address.fAddressType != AF_INET
        || bound_address.fPort == 0) {
        now_log(kLogError, "mirror",
                "UDP bind returned invalid address: len=%lu type=%u port=%u",
                (unsigned long)result.addr.len,
                (unsigned)bound_address.fAddressType,
                (unsigned)bound_address.fPort);
        close_udp("invalid bound address");
        return 0;
    }
    gRequestedPort = port;
    gBoundPort = bound_address.fPort;
    now_log(kLogInfo, "mirror", "UDP requested %u, bound %u",
            (unsigned)gRequestedPort, (unsigned)gBoundPort);
    return 1;
}

int now_continuity_arm(long id, unsigned short port,
                       unsigned long nonce_hi, unsigned long nonce_lo,
                       unsigned long epoch, unsigned long requested_hz,
                       unsigned long lease_ticks, int fast_pump,
                       unsigned long tracking_options)
{
    NowPeekContinuityCell *shared = cell();

    if (shared == NULL || epoch == 0
        || !now_continuity_service_ready(shared)) {
        now_log(kLogWarn, "mirror", "arm refused: resident unavailable");
        return kNowContinuityArmUnsupported;
    }
    if (!open_udp(port)) {
        now_log(kLogError, "mirror", "arm refused: UDP %u unavailable",
                (unsigned)port);
        return kNowContinuityArmTransportUnavailable;
    }
    now_peek_claim(kNowPeekOwnerContinuity,
                   (unsigned long)kNowPeekCapAnchors);
    gNotifierCell = shared;
    gNonceHi = (NowCU32)nonce_hi;
    gNonceLo = (NowCU32)nonce_lo;
    gMalformed = 0;
    gRejected = 0;
    gAckPending = false;
    gAckPublishSeq = 0;
    gAckSends = 0;
    gAckFlowStops = 0;
    gAckRetries = 0;
    gAckErrors = 0;
    gAckGoData = 0;
    gAckRetrying = false;
    shared->apply_result_err = 0;
    shared->apply_result_seq = 0;
    now_continuity_service_begin_epoch(epoch);
    shared->enabled = 1;
    shared->epoch = (NowPeekU32)epoch;
    shared->lease_ticks = (NowPeekU32)lease_ticks;
    shared->requested_hz = (NowPeekU32)requested_hz;
    shared->tracking_options = (NowPeekU32)tracking_options
        & (NowPeekU32)kNowPeekContinuityTrackingKnownMask;
    shared->tracking_pin_writes = 0;
    shared->tracking_getmouse_answers = 0;
    shared->button_edge_deferrals = 0;
    shared->button_edge_overflows = 0;
    shared->tracking_settle_calls = 0;
    shared->tracking_settle_redraws = 0;
    shared->tracking_settle_reasserts = 0;
    memset(&shared->tracking_device_attempts, 0,
           sizeof(*shared)
             - offsetof(NowPeekContinuityCell,
                        tracking_device_attempts));
    bump_nonzero(&shared->control_seq);
    gPendingReplyID = id;
    gPendingControlSeq = shared->control_seq;
    gHaveReportedTerminal = 0;
    if (!now_continuity_service_invoke(shared)) {
        shared->enabled = 0;
        bump_nonzero(&shared->control_seq);
        gEpoch = 0;
        gPendingReplyID = 0;
        gPendingControlSeq = 0;
        now_peek_release(kNowPeekOwnerContinuity,
                         (unsigned long)kNowPeekCapAnchors);
        now_log(kLogError, "mirror",
                "arm refused: resident service unavailable");
        return kNowContinuityArmUnsupported;
    }
    /* Publish notifier authority only after the resident accepted the same
       epoch. A datagram can never outrun construction of its consumer. */
    gEpoch = (NowCU32)epoch;
    gFastPump = fast_pump != 0;
    /* double-active is GetDblTime() AFTER the resident armed: with the wide
       window bit set it must read the widened value, so this line is the
       proof the widening actually installed on this machine - the teardown
       line's double= deliberately reports the human's saved original and
       cannot distinguish a widening that never ran. */
    now_log(kLogInfo, "mirror",
            "arm epoch=%lu hz=%lu lease=%lu fast=%d tracking=0x%lx "
            "double-active=%lu",
            epoch, requested_hz, lease_ticks, gFastPump, tracking_options,
            (unsigned long)GetDblTime());
    now_log_flush();
    return kNowContinuityArmOK;
}

int now_continuity_disarm(long id, unsigned long epoch)
{
    NowPeekContinuityCell *shared = cell();
    NowContinuityCursorDiagnostics cursor;
    unsigned long timing_count;
    unsigned long timing_index;

    if (shared == NULL || (NowPeekU32)epoch != shared->epoch) {
        now_log(kLogWarn, "mirror", "disarm refused epoch=%lu", epoch);
        return 0;
    }
    gEpoch = 0;                    /* datagrams lose authority first */
    gFastPump = 0;
    now_continuity_keyboard_flush(shared);
    now_peek_release(kNowPeekOwnerContinuity,
                     (unsigned long)kNowPeekCapAnchors);
    shared->enabled = 0;
    bump_nonzero(&shared->control_seq);
    gPendingReplyID = id;
    gPendingControlSeq = shared->control_seq;
    gAckPending = false;
    gAckRetrying = false;
    (void)now_continuity_service_invoke(shared);
    now_log(kLogInfo, "mirror", "disarm epoch=%lu reset requested", epoch);
    now_log(kLogInfo, "mirror",
            "tracking epoch=%lu options=0x%lx pin=%lu getmouse=%lu "
            "settle=%lu redraw=%lu reassert=%lu",
            epoch, (unsigned long)shared->tracking_options,
            (unsigned long)shared->tracking_pin_writes,
            (unsigned long)shared->tracking_getmouse_answers,
            (unsigned long)shared->tracking_settle_calls,
            (unsigned long)shared->tracking_settle_redraws,
            (unsigned long)shared->tracking_settle_reasserts);
    now_log(kLogInfo, "mirror",
            "button edges epoch=%lu deferred=%lu overflow=%lu previous=%lu/%lu",
            epoch, (unsigned long)shared->button_edge_deferrals,
            (unsigned long)shared->button_edge_overflows,
            (unsigned long)shared->previous_button_generation,
            (unsigned long)shared->previous_button_flags);
    now_log(kLogInfo, "mirror",
            "tracking points epoch=%lu at=%ld,%ld native=%ld,%ld "
            "owned=%ld,%ld",
            epoch, (long)shared->at_h, (long)shared->at_v,
            (long)shared->native_input_h, (long)shared->native_input_v,
            (long)shared->native_owned_h, (long)shared->native_owned_v);
    now_log(kLogInfo, "mirror",
            "tracking device epoch=%lu attempts=%lu found=%lu moves=%lu "
            "fail=%lu reentry=%lu err=%ld",
            epoch, (unsigned long)shared->tracking_device_attempts,
            (unsigned long)shared->tracking_device_found,
            (unsigned long)shared->tracking_device_moves,
            (unsigned long)shared->tracking_device_failures,
            (unsigned long)shared->tracking_device_reentries,
            (long)shared->tracking_device_last_error);
    now_log(kLogInfo, "mirror",
            "tracking device points before=%ld,%ld after=%ld,%ld held=%ld,%ld",
            (long)shared->tracking_device_last_before_h,
            (long)shared->tracking_device_last_before_v,
            (long)shared->tracking_device_last_after_h,
            (long)shared->tracking_device_last_after_v,
            (long)shared->tracking_device_last_held_h,
            (long)shared->tracking_device_last_held_v);
    timing_count = (unsigned long)shared->event_timing_count;
    if (timing_count > (unsigned long)kNowPeekContinuityEventTimingCapacity)
        timing_count = (unsigned long)kNowPeekContinuityEventTimingCapacity;
    now_log(kLogInfo, "mirror",
            "button timing epoch=%lu double=%lu count=%lu overwritten=%lu",
            epoch, (unsigned long)shared->double_time_ticks, timing_count,
            (unsigned long)shared->event_timing_dropped);
    for (timing_index = 0; timing_index < timing_count; timing_index++) {
        /* The ring keeps the LAST capacity edges; walk chronologically
           from the oldest surviving slot. */
        unsigned long slot =
            ((unsigned long)shared->event_timing_count
             + (unsigned long)kNowPeekContinuityEventTimingCapacity
             - timing_count + timing_index)
            % (unsigned long)kNowPeekContinuityEventTimingCapacity;
        const NowPeekContinuityEventTiming *timing =
            &shared->event_timing[slot];

        now_log(kLogInfo, "mirror",
                "button timing n=%lu gen=%lu down=%lu req=%ld,%ld "
                "arrive=%lu expose=%lu",
                timing_index + 1u, (unsigned long)timing->generation,
                (unsigned long)timing->down,
                (long)timing->request_h, (long)timing->request_v,
                (unsigned long)timing->arrival_ticks,
                (unsigned long)timing->exposure_ticks);
        now_log(kLogInfo, "mirror",
                "button timing n=%lu manager=%lu>%lu err=%ld "
                "event=%lu observed=%lu at=%ld,%ld stable=%lu",
                timing_index + 1u,
                (unsigned long)timing->manager_begin_ticks,
                (unsigned long)timing->manager_end_ticks,
                (long)timing->manager_error,
                (unsigned long)timing->event_when,
                (unsigned long)timing->event_observed_ticks,
                (long)timing->event_h, (long)timing->event_v,
                (unsigned long)timing->write_seq);
    }
    memset(&cursor, 0, sizeof cursor);
    now_continuity_cursor_diagnostics(&cursor);
    now_log(kLogInfo, "mirror",
            "CDM record epoch=%lu samples=%lu before-diff=%lu "
            "press-return=%lu after-diff=%lu",
            epoch, cursor.samples, cursor.before_request_mismatches,
            cursor.press_reversions, cursor.after_request_mismatches);
    now_log(kLogInfo, "mirror",
            "CDM settle epoch=%lu immediate-lag=%lu caught-up=%lu "
            "persisted=%lu pending=%lu",
            epoch, cursor.after_request_mismatches,
            cursor.after_lag_caught_up, cursor.after_lag_persisted,
            cursor.after_lag_pending);
    now_log(kLogInfo, "mirror",
            "CDM points epoch=%lu press=%ld,%ld request=%ld,%ld valid=%d/%d",
            epoch, cursor.press_h, cursor.press_v,
            cursor.requested_h, cursor.requested_v,
            cursor.press_valid, cursor.requested_valid);
    now_log(kLogInfo, "mirror",
            "CDM observed epoch=%lu before=%ld,%ld after=%ld,%ld valid=%d",
            epoch, cursor.before_h, cursor.before_v,
            cursor.after_h, cursor.after_v, cursor.device_point_valid);
    now_log_flush();
    /* The endpoint is transport, not authority. Keep the asynchronous OT
       endpoint bound for this TCP session and reject every packet while the
       epoch is zero. Closing and immediately reopening it at each user
       toggle partially wedged OS 9 on the second arm; disconnect remains the
       one transport teardown boundary. */
    return 1;
}

int now_continuity_key(unsigned long epoch, unsigned long generation,
                       unsigned long action, unsigned long key_code,
                       unsigned long character, unsigned long modifiers)
{
    NowPeekContinuityCell *shared = cell();
    ProcessSerialNumber front;
    unsigned long target_a5 = 0;
    const char *code;
    const char *message;
    int queued;

    if (shared == NULL || epoch == 0 || generation == 0
            || action < (unsigned long)kNowPeekContinuityKeyDown
            || action > (unsigned long)kNowPeekContinuityKeyRepeat
            || key_code > 127UL || character > 255UL
            || modifiers > 65535UL)
        return kNowContinuityKeyMalformed;
    if (gEpoch == 0 || (NowCU32)epoch != gEpoch || !shared->enabled
            || (shared->state != (NowPeekU32)kNowPeekContinuityStateArmed
                && shared->state
                    != (NowPeekU32)kNowPeekContinuityStateActive))
        return kNowContinuityKeyBadEpoch;
    if (GetFrontProcess(&front) != noErr
            || !now_peek_arm_target_a5(
                &front, &target_a5, &code, &message)) {
        now_log(kLogWarn, "mirror", "key target unavailable: %s: %s",
                code, message);
        return kNowContinuityKeyTargetUnavailable;
    }
    queued = now_continuity_keyboard_enqueue(
        shared, (NowPeekU32)generation, (NowPeekU32)target_a5,
        (NowPeekU32)front.highLongOfPSN, (NowPeekU32)front.lowLongOfPSN,
        (NowPeekU32)action, (NowPeekU32)key_code,
        (NowPeekU32)character, (NowPeekU32)modifiers);
    if (queued == kNowContinuityKeyEnqueueOK)
        return kNowContinuityKeyQueued;
    if (queued == kNowContinuityKeyEnqueueFull)
        return kNowContinuityKeyQueueFull;
    return kNowContinuityKeyMalformed;
}

void now_continuity_disconnect(void)
{
    NowPeekContinuityCell *shared;

    gEpoch = 0;                    /* revoke before table or transport work */
    gFastPump = 0;
    now_peek_release(kNowPeekOwnerContinuity,
                     (unsigned long)kNowPeekCapAnchors);
    shared = cell();
    if (shared != NULL && shared->enabled) {
        now_continuity_keyboard_flush(shared);
        shared->enabled = 0;
        bump_nonzero(&shared->control_seq);
    }
    gAckPending = false;
    gAckRetrying = false;
    gPendingReplyID = 0;
    if (shared != NULL)
        (void)now_continuity_service_invoke(shared);
    /* Authority is revoked before any transport work. Keep this process's
       asynchronous endpoint for its lifetime: both a VM and the first metal
       candidate showed that close/reopen churn can take the rest of OT down
       with it, while an epoch of zero rejects every datagram. */
    now_log(kLogWarn, "mirror",
            "disconnect reset requested; UDP endpoint retained");
    now_log_flush();
}

void now_continuity_shutdown(void)
{
    gEpoch = 0;
    gFastPump = 0;
    gNotifierCell = NULL;
    now_peek_release(kNowPeekOwnerContinuity,
                     (unsigned long)kNowPeekCapAnchors);
    close_udp("application shutdown");
    now_continuity_service_shutdown();
}

unsigned short now_continuity_udp_port(void)
{
    return gBoundPort;
}

int now_continuity_wants_fast_pump(void)
{
    return gEpoch != 0 && gFastPump;
}

unsigned long now_continuity_live_epoch(void)
{
    return (unsigned long)gEpoch;
}

int now_continuity_button_is_down(void)
{
    NowPeekContinuityCell *shared;

    if (gEpoch == 0) {
        return 0;
    }
    shared = cell();
    /* The resident's own view of the button, not GetMouse or Button():
       this is the SYNTHETIC gesture the host is driving, and the question
       being asked is whether the host is mid-drag - not whether somebody
       is also pressing the guest's own mouse. */
    return shared != NULL && shared->button_down != 0;
}

/* THE CURSOR PLANE'S PUMP, SEPARATE FROM THE WIRE'S.

   now_continuity_take_report() is the only other caller of the service
   handshake, and it is reachable from conn_service() alone. That made the
   position pump a passenger on the wire's own reentrancy guard: while this
   application is inside a request, now_wire_pump() bounces (wire.c) and the
   cursor stops for the whole of it, however many nested loops pump in
   between. The comment in take_report already claims the renewal happens
   "from the ordinary and NESTED wire pump" - this is the half of that
   sentence that was never true.

   MEASURED 2026-08-13 (log "223323", epoch 12): the host's Mirror cycle
   asks for a scene every 0.75 s of guest-idle time and does not stand down
   while Continuity is armed, so serving it is the once-a-second event. The
   applies came 48-72 ticks apart with a clean 1-tick cadence between, which
   is a loop that is not running rather than a loop running slowly.

   WHAT THIS DELIBERATELY OMITS. No ack, no report, no transport: all three
   need the wire's state machine, which is exactly what cannot be re-entered
   here. The ack is retried by the next ordinary pass and Continuity state is
   absolute, so a skipped one costs nothing. What remains is the owner lease
   and the apply handshake - both idempotent, allocation-free, and already
   guarded against re-entry by now_continuity_service_invoke itself. */
void now_continuity_pump(void)
{
    NowPeekContinuityCell *shared;

    if (gEpoch == 0) {
        return;                       /* no epoch: nothing owns the cursor */
    }
    shared = cell();
    if (shared == NULL) {
        return;
    }
    /* The lease is finite and 90 ticks is inside the stall this exists to
       cover, so it is renewed here for the same reason take_report renews
       it: time we spent serving a request is not time the host went away. */
    now_peek_claim(kNowPeekOwnerContinuity,
                   (unsigned long)kNowPeekCapAnchors);
    (void)now_continuity_service_invoke(shared);
}

int now_continuity_take_report(NowContinuityReport *out)
{
    NowPeekContinuityCell *shared = cell();
    NowPeekU32 before;
    int report_kind;
    int terminal_already_reported;
    long id = 0;

    if (shared == NULL || out == NULL)
        return 0;
    if (gEpoch != 0) {
        /* The owner lease is intentionally finite. Renew from the ordinary
           and nested wire pump while this input epoch is live, so a person
           pausing ten seconds before typing does not discover that the A5
           target plane quietly expired underneath them. */
        now_peek_claim(kNowPeekOwnerContinuity,
                       (unsigned long)kNowPeekCapAnchors);
    }
    /* Every ordinary and nested wire pump services the resident from this
       application's cooperative context. No Time Manager or global jGNE path
       performs Continuity placement. */
    if (!now_continuity_service_invoke(shared))
        return 0;
    try_send_ack(shared);
    before = shared->status_seq;
    if (before & 1)
        return 0;
    terminal_already_reported = gHaveReportedTerminal
        && gLastTerminalEpoch == shared->epoch
        && gLastTerminalReason == shared->exit_reason;
    report_kind = now_continuity_report_kind(
        gPendingReplyID, shared->observed_control_seq, gPendingControlSeq,
        before, gLastReportedStatusSeq, shared->state,
        terminal_already_reported);
    if (report_kind == kNowContinuityReportNone)
        return 0;
    if (report_kind == kNowContinuityReportControl) {
        id = gPendingReplyID;
        gPendingReplyID = 0;
    }
    out->id = id;
    out->epoch = shared->epoch;
    out->state = shared->state;
    out->accepted_hz = shared->accepted_hz;
    out->exit_reason = shared->exit_reason;
    out->accepted_packets = shared->accepted_packets;
    out->stale_packets = shared->stale_packets + gRejected;
    out->malformed_packets = gMalformed;
    out->applied_position_seq = shared->applied_position_seq;
    out->applied_button_generation = shared->applied_button_generation;
    if (before != shared->status_seq)
        return 0;
    gLastReportedStatusSeq = before;
    if (out->state == (NowPeekU32)kNowPeekContinuityStateExited
            || out->state == (NowPeekU32)kNowPeekContinuityStateRefused) {
        /* A correlated disarm/refusal is already the terminal event. Mark it
           too, otherwise the next counter publication emits one duplicate
           unsolicited terminal report before the one-shot gate engages. */
        gLastTerminalEpoch = out->epoch;
        gLastTerminalReason = out->exit_reason;
        gHaveReportedTerminal = 1;
        /* The pointer belongs to the host again: leave no stale guest
           sprite parked at the last synthetic point. ObscureCursor hides
           until the next real mouse movement, which is exactly a
           handback's semantics - and exactly why a guest-input takeover
           is excluded, since there the human IS the next movement and
           wants the sprite where their hand just put it. Idempotent, so
           a duplicated terminal report costs nothing. */
        if (out->state == (NowPeekU32)kNowPeekContinuityStateExited
                && out->exit_reason
                    != (NowPeekU32)kNowPeekContinuityExitGuestInput)
            ObscureCursor();
    }
    now_log(out->state == kNowPeekContinuityStateRefused
                ? kLogWarn : kLogInfo,
            "mirror",
            "report state=%s reason=%s packets=%lu local=%lu resets=%lu event=%lu/%lu fail=%lu",
            now_continuity_state_name(out->state),
            now_continuity_reason_name(out->exit_reason) != NULL
                ? now_continuity_reason_name(out->exit_reason) : "none",
            (unsigned long)out->accepted_packets,
            (unsigned long)shared->local_takeovers,
            (unsigned long)shared->forced_resets,
            (unsigned long)shared->event_down_posts,
            (unsigned long)shared->event_up_posts,
            (unsigned long)shared->event_post_failures);
    now_log(kLogInfo, "mirror",
            "native samples=%lu changes=%lu trigger=%lu at=%ld,%ld",
            (unsigned long)shared->native_input_samples,
            (unsigned long)shared->native_input_changes,
            (unsigned long)shared->native_input_trigger,
            (long)shared->native_input_h, (long)shared->native_input_v);
    now_log(kLogInfo, "mirror",
            "native owned=%ld,%ld buttons=%lu debt-cancels=%lu",
            (long)shared->native_owned_h, (long)shared->native_owned_v,
            (unsigned long)shared->native_buttons,
            (unsigned long)shared->cursor_debt_cancels);
    now_log(kLogInfo, "mirror", "resident service calls=%lu applies=%lu",
            (unsigned long)shared->service_calls,
            (unsigned long)shared->tasktime_cursor_applies);
    now_log(shared->key_failures == 0 && shared->key_dropped == 0
                ? kLogInfo : kLogWarn,
            "mirror",
            "keyboard queued=%lu applied=%lu failed=%lu dropped=%lu "
            "flushes=%lu last=%ld",
            (unsigned long)shared->key_enqueued,
            (unsigned long)shared->key_applied,
            (unsigned long)shared->key_failures,
            (unsigned long)shared->key_dropped,
            (unsigned long)shared->key_flushes,
            (long)shared->key_last_error);
    now_log(kLogInfo, "mirror",
            "button generation=%lu down=%lu timer=%lu forced=%lu pending-up=%lu",
            (unsigned long)shared->applied_button_generation,
            (unsigned long)shared->button_down,
            (unsigned long)shared->button_timer_ticks,
            (unsigned long)shared->button_forced_releases,
            (unsigned long)shared->pending_mouseup);
    now_log(gAckErrors == 0 ? kLogInfo : kLogWarn, "mirror",
            "UDP ack sent=%lu flow=%lu retry=%lu err=%lu go=%lu pending=%u",
            (unsigned long)gAckSends, (unsigned long)gAckFlowStops,
            (unsigned long)gAckRetries, (unsigned long)gAckErrors,
            (unsigned long)gAckGoData, (unsigned)gAckPending);
    now_log(kLogInfo, "mirror", "UDP requested=%u bound=%u",
            (unsigned)gRequestedPort, (unsigned)gBoundPort);
    return 1;
}

const char *now_continuity_state_name(unsigned long state)
{
    switch (state) {
    case kNowPeekContinuityStateArmed: return "armed";
    case kNowPeekContinuityStateActive: return "active";
    case kNowPeekContinuityStateExited: return "exited";
    case kNowPeekContinuityStateRefused: return "refused";
    default: return "inactive";
    }
}

const char *now_continuity_reason_name(unsigned long reason)
{
    switch (reason) {
    case kNowPeekContinuityExitHostLeft: return "host-left";
    case kNowPeekContinuityExitGuestInput: return "guest-input";
    case kNowPeekContinuityExitLeaseExpired: return "lease-expired";
    case kNowPeekContinuityExitDisarmed: return "disarmed";
    case kNowPeekContinuityExitUnavailable: return "unavailable";
    default: return NULL;
    }
}
