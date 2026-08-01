/* The act pump's lifecycle - launch, quit, heartbeat. See act_session.h
   for the shape and for why all three exist.

   Everything here is Toolbox: finding a file, launching a process,
   sending an Apple Event. The decisions - is a pump alive, is the
   session live, has it gone stale - are now_act_guard.c's, which a host
   cc compiles and act_pump_test.c exercises. */

#include <Carbon.h>
#include <string.h>

#include "act_session.h"
#include "now_act_guard.h"
#include "nowlog.h"
#include "peek.h"
#include "peek_table.h"
#include "wire.h"

/* The pump's creator signature, from now-pump/CMakeLists.txt. Found by
   CREATOR rather than by file name on purpose: a name is something a
   person can change with one click in the Finder, and a launcher that
   guesses at a name fails in a way that looks exactly like a component
   that was never installed. */
#define kNowPumpCreator 'NWpu'

static int g_session_open;
/* One launch attempt per session. A pump that cannot start will not
   start on the next event-loop pass either, and retrying sixty times a
   second would turn a missing file into a machine nobody can use. */
static int g_launch_tried;

static NowPeekActPump *session_pump(void)
{
    /* Cast away const: this application WRITES the heartbeat. now_peek_table
       hands out a const view because every other reader on this side only
       reads, and the pump cell is the one region where the application is
       a writer - stated here rather than by widening that accessor for
       everybody. */
    return now_act_pump((NowPeekTable *)now_peek_table());
}

/* Our own folder, which is where the pump ships. */
static OSErr session_app_folder(FSSpec *out)
{
    ProcessSerialNumber psn;
    ProcessInfoRec      info;
    FSSpec              app;
    OSErr               err;

    err = GetCurrentProcess(&psn);
    if (err != noErr) {
        return err;
    }
    memset(&info, 0, sizeof info);
    info.processInfoLength = (long)sizeof info;
    info.processAppSpec = &app;
    err = GetProcessInformation(&psn, &info);
    if (err != noErr) {
        return err;
    }
    *out = app;
    return noErr;
}

/* Walk that folder for a file whose creator is the pump's. Index-order
   catalogue walk rather than the Desktop Database: DTGetAPPL answers for
   the whole VOLUME, and the copy of the pump this build ships beside is
   the one that matches this build's table format. */
static Boolean session_find_pump(FSSpec *out)
{
    FSSpec      app;
    CInfoPBRec  pb;
    Str63       name;
    short       index;

    if (session_app_folder(&app) != noErr) {
        return false;
    }
    for (index = 1; index < 512; index++) {
        memset(&pb, 0, sizeof pb);
        name[0] = 0;
        pb.hFileInfo.ioNamePtr = name;
        pb.hFileInfo.ioVRefNum = app.vRefNum;
        pb.hFileInfo.ioDirID = app.parID;
        pb.hFileInfo.ioFDirIndex = index;
        if (PBGetCatInfoSync(&pb) != noErr) {
            return false;               /* end of the folder */
        }
        if ((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0) {
            continue;                   /* a folder, not a file */
        }
        if (pb.hFileInfo.ioFlFndrInfo.fdCreator
                == (OSType)kNowPumpCreator
            && pb.hFileInfo.ioFlFndrInfo.fdType == (OSType)'APPL') {
            return FSMakeFSSpec(app.vRefNum, app.parID, name, out) == noErr;
        }
    }
    return false;
}

static void session_launch_pump(void)
{
    LaunchParamBlockRec lpb;
    FSSpec              spec;
    OSErr               err;

    if (!session_find_pump(&spec)) {
        now_log(kLogWarn, "act",
                "act pump not found beside this application; clicks fall "
                "back to V3's inline route, which measured as never "
                "arriving");
        return;
    }
    memset(&lpb, 0, sizeof lpb);
    lpb.launchBlockID = extendedBlock;
    lpb.launchEPBLength = extendedBlockLen;
    lpb.launchFileFlags = 0;
    /* launchDontSwitch is not a nicety: it is the difference between a
       pump and a interruption. Bringing a faceless process to the front
       would take the front layer away from the application a click is
       about to be aimed at - and the Event Manager gives a press to
       whoever is frontmost, so the very act of starting the pump would
       break the act it exists to enable. launchContinue keeps US running;
       without it this application would be terminated by the launch. */
    lpb.launchControlFlags = launchContinue | launchNoFileFlags
                             | launchDontSwitch;
    lpb.launchAppSpec = &spec;
    err = LaunchApplication(&lpb);
    if (err != noErr) {
        now_log(kLogWarn, "act", "act pump would not launch (%d)", (int)err);
        return;
    }
    now_log(kLogInfo, "act", "act pump launched");
}

/* Ask the pump to quit, the way a Macintosh asks: kAEQuitApplication to
   its process serial number. No reply is waited for - this runs on the
   way out of a session and the pump's own heartbeat watch is what
   guarantees it goes even if this never arrives. */
static void session_quit_pump(void)
{
    ProcessSerialNumber psn;
    ProcessInfoRec      info;
    Str31               name;

    psn.highLongOfPSN = 0;
    psn.lowLongOfPSN = kNoProcess;
    while (GetNextProcess(&psn) == noErr && psn.lowLongOfPSN != kNoProcess) {
        memset(&info, 0, sizeof info);
        info.processInfoLength = (long)sizeof info;
        info.processName = name;
        if (GetProcessInformation(&psn, &info) != noErr) {
            continue;
        }
        if (info.processSignature != (OSType)kNowPumpCreator) {
            continue;
        }
        {
            AppleEvent  event;
            AppleEvent  reply;
            AEAddressDesc target;

            if (AECreateDesc(typeProcessSerialNumber, (Ptr)&psn,
                             (Size)sizeof psn, &target) != noErr) {
                return;
            }
            if (AECreateAppleEvent(kCoreEventClass, kAEQuitApplication,
                                   &target, kAutoGenerateReturnID,
                                   kAnyTransactionID, &event) == noErr) {
                reply.descriptorType = typeNull;
                reply.dataHandle = NULL;
                (void)AESend(&event, &reply, kAENoReply | kAENeverInteract,
                             kAENormalPriority, kAEDefaultTimeout, NULL,
                             NULL);
                (void)AEDisposeDesc(&event);
            }
            (void)AEDisposeDesc(&target);
        }
        return;                         /* there is only ever one */
    }
}

void now_act_session_service(void)
{
    NowPeekActPump *pump = session_pump();
    unsigned long   now;

    if (pump == NULL) {
        /* No extension, or one that predates the handshake. There is
           nothing to beat at and nothing that could serve a click; the
           plane's own status verbs report that in their own words. */
        return;
    }
    now = (unsigned long)TickCount();

    if (conn_is_connected()) {
        /* The beat FIRST, then the launch: a pump that starts and reads a
           heartbeat that has not been written yet spends its whole grace
           window deciding whether it is an orphan. */
        now_act_session_beat(pump, now);
        if (!g_session_open) {
            g_session_open = 1;
            g_launch_tried = 0;
        }
        if (!g_launch_tried && !now_act_pump_alive(pump, now)) {
            g_launch_tried = 1;
            session_launch_pump();
        }
        return;
    }
    if (g_session_open) {
        g_session_open = 0;
        g_launch_tried = 0;
        now_act_session_end(pump);
        session_quit_pump();
    }
}

void now_act_session_close(void)
{
    NowPeekActPump *pump = session_pump();

    if (pump == NULL) {
        return;
    }
    g_session_open = 0;
    g_launch_tried = 0;
    now_act_session_end(pump);
    session_quit_pump();
}
