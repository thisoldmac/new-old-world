/*
 * NOW Wedge - a Macintosh starving itself on purpose, for a bounded time,
 * so the host's liveness work can be tested without waiting for a modal.
 *
 * WHY THIS EXISTS. On 2026-08-05 the Mirror was driven into the Finder's
 * "could not find the application program that created the document"
 * alert, and the machine went silent for over ninety seconds - not just
 * NOW, but `tbt-worker` too, a background-only application on its own
 * port with no code in common. That is past the host's ~75 s silence
 * window, so the wire died against a perfectly healthy Macintosh.
 *
 * Reproducing that by hand cost a rig: the guest could not be recovered
 * from software (mac99 has no ADB keyboard and no absolute pointer, and
 * the anchor worker's posted click is itself starved), and the staged
 * image had to be abandoned mid-modal. An instrument that starves the
 * machine on request and then LETS GO is the difference between an
 * experiment you can run and one you can run once.
 *
 * THREE MODES, BECAUSE THEY ARE NOT THE SAME EXPERIMENT. Which of these
 * the Finder's alert actually is has never been established, and the
 * difference decides where a fix belongs:
 *
 *   spin  - a loop that never calls WaitNextEvent. Total, deterministic
 *           starvation: the Process Manager only switches when the front
 *           application asks for an event, so nothing else on the machine
 *           runs at all. This is the worst case and the one a resident
 *           liveness channel must survive.
 *   modal - a real modal dialog, left up for the duration. ModalDialog
 *           DOES call GetNextEvent internally, so background applications
 *           should keep getting time - which would mean a modal merely
 *           SITTING there starves nothing, and the ninety seconds came
 *           from something else. Nobody has checked; this is how.
 *   scan  - a long synchronous file-system walk, which is the current
 *           suspect: the alert's "select an alternate program" list has
 *           to enumerate the applications on the volume before it can be
 *           drawn, and that enumeration is not an event loop.
 *
 * BOUNDED AND SELF-RELEASING, always. Every mode stops at its deadline
 * and quits, so the machine comes back on its own and the rig survives
 * the experiment. There is no unbounded mode and there must not be one:
 * the wedge whose recovery needs a person is the one that cost a staged
 * image, and this exists precisely to not be that.
 *
 * WHAT IT PROVES: that the thing under test survives THIS starvation.
 * It says nothing about the Finder's alert - a different application,
 * blocking for its own reasons - exactly as tools/fakeguest.py proves
 * nothing about a guest. The Finder's own modal stays the acceptance
 * test; this is the one you can run a hundred times first.
 *
 * AN INSTRUMENT, NOT A PRODUCT FEATURE. It is staged onto a
 * session-private emulator clone and ships to nobody. It is not a guest
 * verb, deliberately: a "hang this Macintosh" command on the wire would
 * be a permanent hazard in the product to save building a throwaway
 * applet, and command-parity would then oblige both faces to carry it.
 */

#include <Devices.h>
#include <Dialogs.h>
#include <Events.h>
#include <Files.h>
#include <Processes.h>
#include <Quickdraw.h>
#include <Resources.h>
#include <TextUtils.h>
#include <Types.h>

/* The applet's own name says what it will do and for how long, because
   it is launched by name through the anchor worker and there is nowhere
   else to put an argument. Renamed by the rig before staging:

       NOW Wedge spin 30      - starve everything for 30 seconds
       NOW Wedge modal 30     - a modal dialog, up for 30 seconds
       NOW Wedge scan 30      - a synchronous volume walk, ~30 seconds

   Parsed from the process name rather than from a file, so one staged
   binary serves every experiment and the rig chooses by renaming. */

enum {
    kWedgeSpin = 0,
    kWedgeModal = 1,
    kWedgeScan = 2,
    kDefaultSeconds = 30,
    /* A ceiling, not a default. Even an instrument that always lets go
       should not be able to hold a machine for an hour because of a typo
       in a name. */
    kMaxSeconds = 300
};

static void ParseName(short *mode, long *seconds)
{
    ProcessSerialNumber psn;
    ProcessInfoRec info;
    Str255 name;
    short i, argStart;
    long value;

    *mode = kWedgeSpin;
    *seconds = kDefaultSeconds;

    psn.highLongOfPSN = 0;
    psn.lowLongOfPSN = kCurrentProcess;
    info.processInfoLength = sizeof(info);
    info.processName = name;
    info.processAppSpec = NULL;
    if (GetProcessInformation(&psn, &info) != noErr) return;

    /* "NOW Wedge <mode> <seconds>", read with the Toolbox's own string
       calls rather than C's: this is a Pascal string and there is no
       terminator to trust. */
    if (name[0] == 0) return;

    for (i = 1; i <= name[0]; i++) {
        if (name[i] == 'm' && i + 4 <= name[0]
            && name[i + 1] == 'o' && name[i + 2] == 'd') {
            *mode = kWedgeModal;
            break;
        }
        if (name[i] == 's' && i + 3 <= name[0]
            && name[i + 1] == 'c' && name[i + 2] == 'a') {
            *mode = kWedgeScan;
            break;
        }
    }

    /* The trailing number, if there is one. */
    argStart = 0;
    for (i = name[0]; i >= 1; i--) {
        if (name[i] < '0' || name[i] > '9') break;
        argStart = i;
    }
    if (argStart == 0) return;
    value = 0;
    for (i = argStart; i <= name[0]; i++) {
        value = value * 10 + (name[i] - '0');
        if (value > kMaxSeconds) { value = kMaxSeconds; break; }
    }
    if (value > 0) *seconds = value;
}

/* **The start of the block is announced by the applet's own NAME**, which
   the process list already carries and which the rig sets when it stages
   a run. There is deliberately no DebugStr: on a machine with no debugger
   installed — which is every machine this runs on — DebugStr raises a
   system error, and an instrument whose entire justification is that it
   lets go again must not have a failure mode that needs a person to
   dismiss a dialog. That is the wedge it exists to replace. */

static void SpinUntil(unsigned long deadline)
{
    /* NOT WaitNextEvent, and not SystemTask either. The Process Manager
       switches applications when the front one asks for an event, so a
       loop that only reads the tick count starves every other process on
       the machine - which is the whole experiment. */
    while (TickCount() < deadline) {
        /* deliberately empty */
    }
}

static void ScanUntil(unsigned long deadline)
{
    /* A synchronous catalogue walk of the boot volume, restarted until
       the deadline. PBGetCatInfoSync does not yield, so this starves the
       machine for as long as it runs - the suspected shape of the
       Finder's own "which application opens this?" enumeration. */
    CInfoPBRec pb;
    Str255 name;
    short index;

    while (TickCount() < deadline) {
        for (index = 1; TickCount() < deadline; index++) {
            name[0] = 0;
            pb.hFileInfo.ioNamePtr = name;
            pb.hFileInfo.ioVRefNum = 0;
            pb.hFileInfo.ioFDirIndex = index;
            pb.hFileInfo.ioDirID = fsRtDirID;
            if (PBGetCatInfoSync(&pb) != noErr) break;
        }
    }
}

static void ModalUntil(unsigned long deadline)
{
    /* A real modal, put up and left up. ModalDialog is NOT used: it would
       return on the first event and this must hold the dialog for the
       duration. The loop pumps the way ModalDialog does - GetNextEvent -
       so the question this mode exists to answer is whether that is
       enough for other applications to keep running. */
    DialogPtr dialog;
    EventRecord event;

    dialog = GetNewDialog(128, NULL, (WindowPtr)-1L);
    if (dialog == NULL) {
        /* No DLOG resource is not a reason to return instantly and look
           like a mode that did nothing. Fall back to the honest worst
           case — a run that starved MORE than it claimed is readable in
           the result; one that starved nothing looks like a passing
           test. */
        SpinUntil(deadline);
        return;
    }
    ShowWindow(dialog);
    DrawDialog(dialog);
    while (TickCount() < deadline) {
        if (GetNextEvent(everyEvent, &event)) {
            /* Swallowed: a person clicking must not dismiss the
               experiment early, or a run's duration stops being the
               thing the name asked for. */
        }
    }
    DisposeDialog(dialog);
}

int main(void)
{
    short mode;
    long seconds;
    unsigned long deadline;

    InitGraf(&qd.thePort);
    InitFonts();
    InitWindows();
    InitMenus();
    TEInit();
    InitDialogs(NULL);

    ParseName(&mode, &seconds);

    deadline = TickCount() + (unsigned long)(seconds * 60);

    switch (mode) {
    case kWedgeModal: ModalUntil(deadline); break;
    case kWedgeScan:  ScanUntil(deadline);  break;
    default:          SpinUntil(deadline);  break;
    }

    /* Quitting is the release. Nothing else has to happen for the machine
       to come back, which is the property that makes this runnable more
       than once. */
    return 0;
}
