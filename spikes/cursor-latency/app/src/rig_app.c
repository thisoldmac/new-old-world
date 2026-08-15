/*
 * rig_app.c - CursorRig's intake. A PowerPC Carbon application whose
 * only job is to get positions off the wire and into the resident's
 * mailbox, at a moment that does not depend on it being scheduled.
 *
 * THIS IS A RIG. See README.md.
 *
 * The whole design turns on one property of Open Transport: an async
 * endpoint's NOTIFIER is called at deferred-task time, not at
 * application time. So it runs while some other application sits in a
 * tracking loop and this one does not get the processor at all - which
 * is exactly the condition the spike exists to measure, and exactly the
 * condition under which an ordinary "read the socket in the event loop"
 * intake stops reading. Whether that property actually holds on this
 * machine is a RESULT, not an assumption, and the rig can tell: the
 * notifier stamps its own arrival ticks, and the event loop stamps a
 * separate app_passes counter beside them. If the intake is starved,
 * the arrival gaps say so; if only the application is starved,
 * app_passes stalls while arrivals keep coming.
 *
 * There is no window. A rig that draws is a rig that competes with the
 * thing it measures, and the only picture worth watching during a run
 * is the pointer.
 *
 * UDP, and absolute positions only. A dropped datagram costs one stale
 * frame; a dropped delta would corrupt every position after it.
 */

#include <Carbon.h>
#include <OpenTransport.h>
#include <OpenTptInternet.h>

#include <string.h>

#include "cursor_rig.h"

#define kRigDefaultPort 17400

/* Generated at build time (tools/gen_build_id.py). The intake stamps it
   into the table so the host can refuse to believe a build it did not
   stage - see the table's build_id comment. */
extern const RigU32 kRigAppBuildId;

static OTClientContextPtr gOTContext;
static EndpointRef        gEndpoint;
static OTNotifyUPP        gNotifierUPP;
static RigTable          *gTable;
static Boolean            gQuit;

/* Preallocated receive machinery. Nothing here is allocated after
   start-up: the notifier runs at deferred-task time, where allocation
   is not allowed, and an allocation that MOVED memory would perturb the
   very timing being measured. */
static TUnitData   gRcv;
static InetAddress gFrom;
static char        gRcvBuf[256];

/* Reply machinery, used only from the event loop (see below). */
static TUnitData   gSnd;
static InetAddress gReplyTo;
static RigDumpReply gReply;

/* Set by the notifier, drained by the event loop. A dump is answered
   AFTER a run, so answering it from the loop costs nothing and keeps
   every send off the measured path. */
static volatile Boolean gDumpWanted;
static volatile RigU32  gDumpFrom;
static Boolean          gHaveReplyAddr;

static RigU32 now_ticks(void)
{
    return (RigU32)TickCount();
}

/* ------------------------------------------------------------ intake */

static void handle_command(const RigCommand *cmd)
{
    RigTable *t = gTable;

    if (t == NULL) {
        return;
    }
    t->intake_calls++;

    switch (cmd->op) {
    case kRigOpMove:
    case kRigOpClick:
        if (t->armed) {
            rig_intake_stamp(t, cmd, now_ticks());
        }
        break;

    case kRigOpBeginRun:
        /* arg selects who applies the position. Only the Time Manager
           writer is implemented, and an unimplemented mode REFUSES
           rather than quietly running the other one - a number
           attributed to the wrong writer is worse than no number. */
        if (cmd->arg != kRigModeTimer) {
            break;
        }
        rig_ring_reset(t);
        t->mode = kRigModeTimer;
        t->run_seed = cmd->host_stamp;
        t->run_start_ticks = now_ticks();
        t->armed = 1;
        break;

    case kRigOpEndRun:
        t->armed = 0;
        break;

    case kRigOpDump:
        gDumpFrom = (RigU32)cmd->arg;
        gDumpWanted = true;
        break;

    case kRigOpPing:
        /* Answered from here, at intake time, on purpose: this is the
           wire-only measurement and putting the reply in the event loop
           would fold application scheduling into a number that is
           supposed to be about the wire. */
        gReplyTo = gFrom;
        gHaveReplyAddr = true;
        gSnd.addr.buf = (UInt8 *)&gReplyTo;
        gSnd.addr.len = sizeof(gReplyTo);
        gSnd.opt.buf = NULL;
        gSnd.opt.len = 0;
        gSnd.udata.buf = (UInt8 *)cmd;
        gSnd.udata.len = kRigCommandSize;
        OTSndUData(gEndpoint, &gSnd);
        break;

    case kRigOpLoad:
        /* Handed to the starver through the table. The intake only
           writes the request; whether anything is listening is the
           starver's business, and load_running says so afterwards. */
        t->load_profile = (RigU32)cmd->arg;
        t->load_ticks = (RigU32)cmd->h;
        t->load_seq++;
        break;

    case kRigOpQuit:
        gQuit = true;
        break;

    default:
        break;
    }
}

static void drain_endpoint(void)
{
    OTFlags flags;
    RigCommand cmd;

    for (;;) {
        gRcv.addr.buf = (UInt8 *)&gFrom;
        gRcv.addr.maxlen = sizeof(gFrom);
        gRcv.addr.len = 0;
        gRcv.opt.buf = NULL;
        gRcv.opt.maxlen = 0;
        gRcv.opt.len = 0;
        gRcv.udata.buf = (UInt8 *)gRcvBuf;
        gRcv.udata.maxlen = sizeof(gRcvBuf);
        gRcv.udata.len = 0;

        if (OTRcvUData(gEndpoint, &gRcv, &flags) != noErr) {
            return;
        }
        if (gRcv.udata.len < kRigCommandSize) {
            continue;
        }
        /* memcpy rather than a cast: the buffer's alignment is the
           endpoint's business, and the layout agreement is the header's
           (both guests are big-endian, and the host packs explicitly). */
        memcpy(&cmd, gRcvBuf, sizeof(cmd));
        if (cmd.magic != kRigWireMagic || cmd.version != kRigWireVersion) {
            continue;
        }
        gReplyTo = gFrom;
        gHaveReplyAddr = true;
        handle_command(&cmd);
    }
}

static pascal void rig_notifier(void *context, OTEventCode code,
                                OTResult result, void *cookie)
{
    (void)context;
    (void)result;
    (void)cookie;

    switch (code) {
    case T_DATA:
        drain_endpoint();
        break;
    case T_UDERR:
        /* An unreported datagram error latches the endpoint: until it
           is collected, nothing else arrives. Silence here would read
           exactly like a wire that went quiet. */
        OTRcvUDErr(gEndpoint, NULL);
        break;
    default:
        break;
    }
}

/* ------------------------------------------------------------- dump */

static void send_dump(RigU32 first)
{
    RigTable *t = gTable;
    RigU32 i;
    RigU32 count;

    if (t == NULL || !gHaveReplyAddr) {
        return;
    }
    count = kRigDumpChunk;
    if (first >= t->ring_cap) {
        return;
    }
    if (first + count > t->ring_cap) {
        count = t->ring_cap - first;
    }

    memset(&gReply, 0, sizeof(gReply));
    gReply.magic = kRigDumpMagic;
    gReply.first = first;
    gReply.count = count;
    gReply.caps = t->caps;
    gReply.ring_count = t->ring_count;
    gReply.ring_head = t->ring_head;
    gReply.ring_cap = t->ring_cap;
    gReply.ring_dropped = t->ring_dropped;
    gReply.received = t->received;
    gReply.applied = t->applied;
    gReply.coalesced = t->coalesced;
    gReply.out_of_order = t->out_of_order;
    gReply.timer_ticks = t->timer_ticks;
    gReply.intake_calls = t->intake_calls;
    gReply.app_passes = t->app_passes;
    gReply.gne_passes = t->gne_passes;
    gReply.redraws = t->redraws;
    gReply.redraw_calls = t->redraw_calls;
    gReply.place_route = t->place_route;
    gReply.run_seed = t->run_seed;
    gReply.run_start_ticks = t->run_start_ticks;
    gReply.last_apply_ticks = t->last_apply_ticks;
    gReply.now_ticks = now_ticks();
    gReply.armed = t->armed;
    gReply.mode = t->mode;
    gReply.build_id = t->build_id;
    gReply.app_build_id = t->app_build_id;
    gReply.load_profile = t->load_profile;
    gReply.load_running = t->load_running;
    gReply.refused = t->refused;
    gReply.load_started = t->load_started;
    gReply.load_ticks = t->load_ticks;
    for (i = 0; i < count; ++i) {
        gReply.samples[i] = t->ring[first + i];
    }

    gSnd.addr.buf = (UInt8 *)&gReplyTo;
    gSnd.addr.len = sizeof(gReplyTo);
    gSnd.opt.buf = NULL;
    gSnd.opt.len = 0;
    gSnd.udata.buf = (UInt8 *)&gReply;
    gSnd.udata.len = sizeof(gReply);
    OTSndUData(gEndpoint, &gSnd);
}

/* ------------------------------------------------------------ set-up */

static OSStatus open_wire(UInt16 port)
{
    OTConfigurationRef config;
    OSStatus err;
    TEndpointInfo info;
    TBind req;
    TBind ret;
    InetAddress bindAddr;
    InetAddress boundAddr;

    err = InitOpenTransportInContext(kInitOTForApplicationMask, &gOTContext);
    if (err != noErr) {
        return err;
    }
    config = OTCreateConfiguration("udp");
    if (config == NULL || config == (OTConfigurationRef)kOTInvalidConfigurationPtr) {
        return kOTBadConfigurationErr;
    }
    gEndpoint = OTOpenEndpointInContext(config, 0, &info, &err, gOTContext);
    if (err != noErr) {
        return err;
    }

    /* A UPP, not a cast. On CFM a routine descriptor is what makes a
       callback callable from code compiled for another architecture,
       and casting a function pointer into a UPP is the defect this
       project has a finding about (carbon-upp-is-not-a-cast-on-cfm). */
    gNotifierUPP = NewOTNotifyUPP(rig_notifier);
    err = OTInstallNotifier(gEndpoint, gNotifierUPP, NULL);
    if (err != noErr) {
        return err;
    }
    err = OTSetAsynchronous(gEndpoint);
    if (err != noErr) {
        return err;
    }

    OTInitInetAddress(&bindAddr, port, kOTAnyInetAddress);
    req.addr.buf = (UInt8 *)&bindAddr;
    req.addr.len = sizeof(bindAddr);
    req.addr.maxlen = sizeof(bindAddr);
    req.qlen = 0;
    ret.addr.buf = (UInt8 *)&boundAddr;
    ret.addr.len = 0;
    ret.addr.maxlen = sizeof(boundAddr);
    ret.qlen = 0;
    return OTBind(gEndpoint, &req, &ret);
}

/* The resident is required, and its absence is reported rather than
   worked around. An intake that measured itself against a table of its
   own would be measuring a different code path from the one under
   test - and would produce numbers that look exactly as valid. */
static Boolean find_table(void)
{
    long response = 0;

    if (Gestalt((OSType)kRigGestaltSelector, &response) != noErr) {
        return false;
    }
    gTable = (RigTable *)response;
    if (gTable == NULL || gTable->magic != kRigTableMagic
        || gTable->format != kRigTableFormat
        || gTable->length < (RigU32)sizeof(RigTable)) {
        gTable = NULL;
        return false;
    }
    gTable->app_build_id = kRigAppBuildId;
    return true;
}

/* A dialog, because a headless application that failed at start-up is
   indistinguishable from one that is working and being ignored. */
static void complain(const char *pstr)
{
    ParamText((ConstStr255Param)pstr, (ConstStr255Param)"\p",
              (ConstStr255Param)"\p", (ConstStr255Param)"\p");
    StopAlert(128, NULL);
}

int main(void)
{
    EventRecord event;
    UInt16 port = kRigDefaultPort;

    if (!find_table()) {
        complain("\pCursorRig: the CursorRig extension is not resident. "
                 "Install it in the System Folder and COLD-boot.");
        return 1;
    }
    if (open_wire(port) != noErr) {
        complain("\pCursorRig: could not open the UDP endpoint.");
        return 1;
    }

    while (!gQuit) {
        /* Counted before anything else in the pass, so the series means
           "this application got the processor" and not "this
           application finished a pass". Under a tracking loop the two
           differ by exactly the thing being measured. */
        gTable->app_passes++;

        if (gDumpWanted) {
            gDumpWanted = false;
            send_dump(gDumpFrom);
        }
        if (WaitNextEvent(everyEvent, &event, 1, NULL)) {
            if (event.what == keyDown
                && (event.modifiers & cmdKey) != 0
                && (char)(event.message & charCodeMask) == 'q') {
                gQuit = true;
            }
        }
    }

    if (gEndpoint != kOTInvalidEndpointRef) {
        OTCloseProvider(gEndpoint);
    }
    if (gNotifierUPP != NULL) {
        DisposeOTNotifyUPP(gNotifierUPP);
    }
    CloseOpenTransportInContext(gOTContext);
    return 0;
}
