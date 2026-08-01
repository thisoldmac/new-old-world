/*
 * main.c - the mirror agent: a faceless PPC application that serves the scene
 * and action planes over Open Transport.
 *
 * Faceless on purpose. The agent must observe *other* applications' UI, so it
 * must not be the interesting one: no window, no menu bar, nothing that changes
 * what the host is trying to see. It owns the Toolbox itself (no RetroConsole -
 * that Type-11s pre-main on some targets) and yields the CPU generously so the
 * applications it watches keep running normally.
 *
 * Target: PowerPC, Mac OS 9.1 (mac99). PPC is what lets the transport be Open
 * Transport at all - a 68K build cannot link OT under Retro68 (ASLM), which is
 * why the lab's 68K workers speak MacTCP instead.
 *
 * A change to THIS file moves the build stamp `hello` reports. That is not
 * incidental: the stamp used to be __DATE__/__TIME__ compiled into
 * mirrorverbs.c, so a build whose only change was main.c shipped a binary that
 * still claimed the previous build and a deploy could not be confirmed. It is
 * now a hash over every source (cmake/buildstamp.cmake), so any file here
 * moves it. Reproduced by mutation 2026-07-31: with the old macro restored, a
 * main.c-only edit left the stamp byte-identical.
 */
#include "mirrorverbs.h"
#include "ot.h"

#include <Quickdraw.h>
#include <Fonts.h>
#include <MacWindows.h>
#include <Menus.h>
#include <TextEdit.h>
#include <Dialogs.h>
#include <Events.h>
#include <Processes.h>
#include <Files.h>
#include <AppleEvents.h>
#include <AERegistry.h>
#include <LowMem.h>
#include <MacMemory.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

/* The guest port the host dials. Overridable by a `mirror.port` file next to
 * the app, so a second agent can be staged on another port without a rebuild
 * (the "deploy the new build beside the old one" workflow). Config files are
 * role-named, not binary-named, so renaming the app never breaks a deploy. */
#define kDefaultPort 1420
#define kPortFile    "mirror.port"
#define kLogFile     "mirror.log"

/* Good-citizen idle sleep. ot_sleep_ticks shortens this while a request is in
 * flight, so a polling host does not pay it per round-trip. */
#define kSleepTicks  10

/* Events this agent takes out of the queue.
 *
 * `everyEvent` looks wrong for a faceless agent that injects keystrokes for the
 * FRONT application to consume — it makes this process a rival consumer of its
 * own injected events. That reasoning is WRONG here, and measurement said so:
 * narrowing the mask to (highLevelEventMask | osMask) took cmd+N actuation from
 * 9/20 to 0/20 on mac99 (2026-07-29, N=20 per configuration). Whatever the
 * broad mask does for the Event Manager, the front app needs it.
 *
 * So: broad mask, kept deliberately, with the experiment recorded so nobody
 * "cleans this up" on the same plausible reasoning. See docs/STATUS.md. */
#define kAgentEventMask  everyEvent

int           g_shutdown = 0;
unsigned long g_start_ticks = 0;
unsigned long g_last_activity = 0;

static FILE *g_log = NULL;

static void log_line(const char *msg)
{
    if (g_log == NULL) {
        return;
    }
    fprintf(g_log, "[%lu] %s\n", (unsigned long)LMGetTicks(), msg);
    fflush(g_log);          /* a wedge investigation needs the line ON DISK */
}

/* The verb layer's trace hook (mirrorverbs.h). Same file, same flush
 * discipline, so a verb's last words survive whatever happens next. */
void mirror_log(const char *msg)
{
    log_line(msg);
}

/* We own the Toolbox; init it before any Manager call. InitDialogs(NULL) and
 * TEInit are not optional even for a faceless app - the AX plane reads
 * DialogRecords and TextEdit state in other processes, and the Managers must be
 * initialised in ours before those calls are legal. */
static void app_init_toolbox(void)
{
    InitGraf(&qd.thePort);
    InitFonts();
    InitWindows();
    InitMenus();
    TEInit();
    InitDialogs(NULL);
    /* No InitCursor: a faceless agent must not touch the cursor, which the
     * click plane owns and the host is watching. */
    MoreMasters();
    MoreMasters();
}

/* Point the default directory at the app's OWN folder so mirror.port and
 * mirror.log resolve there whatever cwd our launcher hands us -
 * LaunchApplication does NOT set cwd to the app's folder, so a bare
 * fopen("mirror.port") otherwise misses the file entirely. */
static void set_dir_to_app(void)
{
    ProcessSerialNumber psn;
    ProcessInfoRec      info;
    FSSpec              appSpec;

    if (GetCurrentProcess(&psn) != noErr) {
        return;
    }
    memset(&info, 0, sizeof(info));
    info.processInfoLength = sizeof(info);
    info.processAppSpec = &appSpec;
    if (GetProcessInformation(&psn, &info) != noErr) {
        return;
    }
    (void)HSetVol(NULL, appSpec.vRefNum, appSpec.parID);
}

static long read_port(void)
{
    FILE *f = fopen(kPortFile, "r");
    long  port = 0;

    if (f == NULL) {
        return kDefaultPort;
    }
    if (fscanf(f, "%ld", &port) != 1) {
        port = 0;
    }
    fclose(f);
    /* Reject nonsense rather than bind something surprising; a typo in a config
     * file must not silently become a listener on a privileged port. */
    if (port < 1024 || port > 65535) {
        return kDefaultPort;
    }
    return port;
}

/* Honour the quit Apple Event. Not decoration: an installer or a supervisor
 * that sends kAEQuitApplication and gets no answer HANGS, and a guest app that
 * cannot be reaped has to be killed by rebooting the machine. */
static pascal OSErr handle_quit_ae(const AppleEvent *ae, AppleEvent *reply,
                                  long refcon)
{
#pragma unused(ae, reply, refcon)
    g_shutdown = 1;
    return noErr;
}

int main(void)
{
    EventRecord ev;
    OSStatus    err;
    long        port;

    app_init_toolbox();
    set_dir_to_app();

    g_start_ticks = (unsigned long)LMGetTicks();
    g_last_activity = g_start_ticks;

    g_log = fopen(kLogFile, "a");
    port = read_port();

    {
        char b[96];
        snprintf(b, sizeof b, "mirror agent starting: port=%ld", port);
        log_line(b);
    }

    /* No ot_configure: the default disables send pacing, which exists for the
     * PowerBook 1400c's Farallon card dropping back-to-back TX frames. mac99
     * does not need it, and enabling it here would cost latency for nothing.
     * A metal bring-up on that machine is where it gets turned on. */

    err = ot_startup();
    if (err != noErr) {
        char b[64];
        snprintf(b, sizeof b, "OT startup failed: err %ld", (long)err);
        log_line(b);
        return 1;
    }
    err = ot_serve((InetPort)port, mirror_verb_handle, log_line);
    if (err != noErr) {
        char b[80];
        snprintf(b, sizeof b, "serve failed: err %ld on port %ld",
                 (long)err, port);
        log_line(b);
        ot_shutdown();
        return 1;
    }

    {
        AEEventHandlerUPP q = NewAEEventHandlerUPP(handle_quit_ae);
        if (q != NULL) {
            AEInstallEventHandler(kCoreEventClass, kAEQuitApplication,
                                  q, 0, false);
        }
    }
    log_line("listening");

    for (;;) {
        /* Dispatch high-level events explicitly: WaitNextEvent DELIVERS the
         * quit AE but does not process it, so without AEProcessAppleEvent the
         * event is received and dropped and the app never dies. */
        if (WaitNextEvent(kAgentEventMask, &ev,
                          (unsigned long)ot_sleep_ticks(kSleepTicks), NULL)) {
            if (ev.what == kHighLevelEvent) {
                (void)AEProcessAppleEvent(&ev);
            }
        }
        ot_idle();
        /* Never exit mid-send: the host's reply must be fully on the wire
         * before the endpoint goes away, or a clean `quit` looks like a crash. */
        if (g_shutdown && !ot_is_sending()) {
            break;
        }
    }

    log_line("shutting down");
    ot_teardown();
    ot_shutdown();
    if (g_log != NULL) {
        fclose(g_log);
    }
    return 0;
}
