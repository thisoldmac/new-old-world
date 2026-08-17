#include "continuity_dragmgr.h"

#include <Carbon.h>
#include <Drag.h>

#include <stdio.h>
#include <string.h>

#include "continuity_intake.h"
#include "continuity_offer_intake.h"
#include "fileshare.h"
#include "now_continuity_drag.h"
#include "nowlog.h"
#include "wire.h"

/* EVERY LINE HERE LOGS UNDER "mirror", not under a word of its own.
   docs/logging.md's area vocabulary is closed on purpose - an ad-hoc
   word is one nobody knows to grep for - and this is not a new
   subsystem: an armed drag is an arm on the Mirror plane, and the
   offer it picks up already logs there (continuity_offer_intake.c).
   Minting "drag" would split one crossing's story across two words.
   The lines say "drag" in the MESSAGE so they still read as a group. */

static NowContinuityDragState g_drag;
static DragSendDataUPP g_send_upp;

/* ---- SLICE-2 DIAGNOSTIC SCAFFOLD. NOT PRODUCT. -------------------
   Set from the console (`offer --drag --x=<mask>`) so one boot can run
   the whole experiment matrix rather than one hypothesis per build,
   which at ~20 minutes a build/spin cycle is the difference between an
   afternoon and a week. Every bit here is a QUESTION, and whichever
   one turns out to be the answer becomes ordinary code with a reason
   attached; the rest, and this whole block, come out.

     2  omit the kFlavorTypeClippingName hint. Tests whether 'clnm'
        diverts the Finder onto its clipping path, where a promised
        HFS file is not what it is looking for.
     4  install OUR OWN tracking and receive handlers on OUR OWN window,
        so the drop has a receiver whose source is in this repository.
     8  SLICE-0 ROUTE A': attach a SetDragInputProc that reports the
        continuity plane's latest point and button to the Drag Manager,
        so the drag is steered by the host's reported pointer rather
        than by a Cursor Device this application's blocked task time
        cannot move.
    16  the same input proc, but replaying an IN-APP scripted ramp to a
        baked target instead of reading the plane - the deterministic
        control for bit 8, so "the proc is never called" and "the plane
        is stale inside TrackDrag" cannot share one frozen coordinate.
        Wins over 8 when both are set.
    32  materialise the promise in the Temporary Items folder instead of
        the folder the receiver named, and hand the receiver THAT spec.
        Asks whether the receiver places the file itself - the half of
        "who owns the destination" that a file already sitting at its
        destination can never answer.

   Bit 1 was here and is gone: it held the DragRef past TrackDrag on the
   theory that the Finder asks late. Bit 4 killed that theory by showing
   the ask arriving INSIDE TrackDrag, synchronously, the moment a
   receiver exists at all - and holding the DragRef also broke a real
   product guard (continuity_dragmgr_source_test: every return past a
   successful NewDrag must DisposeDrag). A scaffold is not worth
   weakening a gate that is right. */
static long g_diag_mask;
/* Did the send-data callback arrive at all, and was it after TrackDrag
   had already returned? Two different facts and the second one is the
   whole point of bit 1. */
static long g_diag_asks;
static Boolean g_diag_tracking;
static long g_diag_late_asks;

/* Where a bit-16 scripted drag is told to go, and how long it takes to
   get there. Set beside the mask (`offer --drag --x=16@10,300`) so one
   boot can aim at the desktop, at a Finder window and at nowhere at all
   without three builds. */
static short g_diag_script_h = 10;
static short g_diag_script_v = 300;

void now_continuity_dragmgr_diag(long mask)
{
    g_diag_mask = mask;
}

void now_continuity_dragmgr_diag_target(short h, short v)
{
    g_diag_script_h = h;
    g_diag_script_v = v;
}

/* The one drag item; see the note at its original home below. */
enum { kOfferItemRef = 1 };

/* ---- DIAGNOSTIC bit 4: A CONTROL MADE OF CODE WE OWN ---------------
   Every measurement so far has asked the Finder a question and read
   silence as an answer, which cannot tell "our promise is malformed"
   from "the Finder never saw this drag". A control has to be a receiver
   whose source is ours, so a negative means something.

   So NOW installs its own tracking and receive handlers on its own
   window and the drop happens INSIDE it. If the promise is asked for
   there, the sender half is correct and the defect is in delivery to
   another process; if it is not asked for even by a handler we wrote,
   the defect is in what this drag DECLARES and no Finder was ever going
   to ask. (docs: a probe's control must target our own source.) */
static DragTrackingHandlerUPP g_diag_track_upp;
static DragReceiveHandlerUPP g_diag_recv_upp;
static long g_diag_track_msgs;

static pascal OSErr diag_tracking(DragTrackingMessage message,
                                  WindowRef window, void *refcon,
                                  DragRef drag)
{
    (void)window; (void)refcon; (void)drag;
    g_diag_track_msgs++;
    /* Only the edges, and never every pass: kDragTrackingInWindow
       arrives dozens of times a second and would bury the log. */
    if (message == kDragTrackingEnterWindow
        || message == kDragTrackingLeaveWindow
        || message == kDragTrackingEnterHandler) {
        now_log(kLogInfo, "mirror", "drag ctrl: tracking msg=%d",
                (int)message);
    }
    return noErr;
}

static pascal OSErr diag_receive(WindowRef window, void *refcon, DragRef drag)
{
    FSSpec spec;
    Size size = (Size)sizeof spec;
    OSErr err;
    short vref = 0;
    long dir = 0;
    AEDesc where;

    (void)window; (void)refcon;

    now_log(kLogInfo, "mirror", "drag ctrl: RECEIVE handler ran");

    /* Say where, the way a real receiver does — the sender's send proc
       reads this back with GetDropLocation, and a promise with nowhere
       to go is a different failure from one nobody asked for. */
    if (FindFolder(kOnSystemDisk, kDesktopFolderType, kDontCreateFolder,
                   &vref, &dir) == noErr
        && FSMakeFSSpec(vref, dir, (ConstStr255Param)"\p", &spec) == noErr
        && AECreateDesc(typeFSS, &spec, sizeof spec, &where) == noErr) {
        SetDropLocation(drag, &where);
        AEDisposeDesc(&where);
    }

    /* THE ASK. This is the exact call the Finder would make, from code
       whose source is in this repository. */
    err = GetFlavorData(drag, kOfferItemRef, kDragPromisedFlavor, &spec,
                        &size, 0);
    now_log(kLogInfo, "mirror",
            "drag ctrl: GetFlavorData('fssP') -> %d, size=%ld", (int)err,
            (long)size);
    return noErr;
}

static void diag_install_handlers(void)
{
    WindowRef win = FrontWindow();

    if (win == NULL || g_diag_track_upp != NULL) {
        return;
    }
    g_diag_track_upp = NewDragTrackingHandlerUPP(diag_tracking);
    g_diag_recv_upp = NewDragReceiveHandlerUPP(diag_receive);
    if (g_diag_track_upp == NULL || g_diag_recv_upp == NULL) {
        now_log(kLogError, "mirror", "drag ctrl: no handler UPPs");
        return;
    }
    now_log(kLogInfo, "mirror", "drag ctrl: handlers installed t=%d r=%d",
            (int)InstallTrackingHandler(g_diag_track_upp, win, NULL),
            (int)InstallReceiveHandler(g_diag_recv_upp, win, NULL));
}

/* ---- DIAGNOSTIC bits 8 and 16: ROUTE A', THE MANAGER'S OWN SEAM ------
   The 2026-08-17 measurement found that a NOW-originated drag cannot
   leave NOW because the POINTER never leaves: Continuity applies Cursor
   Device motion at task time only, and a drag source's TrackDrag
   consumes this application's task time for the whole drag, so the pump
   starves. SetDragInputProc is the Drag Manager's published answer to
   exactly that - the source hands the Manager a mouse sample every time
   the Manager wants one, from inside TrackDrag, in our own context. The
   header says CarbonLib 1.0 and later (Drag.h, `SetDragInputProc`), so
   the CarbonLib 1.6 floor this application already requires carries it.

   THIS PROC DOES BOUNDED WORK AND NOTHING ELSE. It is called at the
   Manager's sampling rate inside a nested Toolbox loop: no allocation,
   no Toolbox call that can move memory, no logging. Counters here, and
   one line about them after TrackDrag has returned.

   The button lives in `*modifiers`, not in a parameter of its own:
   classic Event Manager `btnState` is SET when the button is UP, so
   reporting a held button means CLEARING it. That inversion is the one
   thing about this contract easy to get backwards, and getting it
   backwards would present as a drag that drops instantly. */
static DragInputUPP g_diag_input_upp;
static long g_diag_input_calls;      /* the Manager sampled us            */
static long g_diag_input_fed;        /* ...and we had something to say    */
static unsigned long g_diag_input_first_seq;
static unsigned long g_diag_input_last_seq;
static short g_diag_input_first_h, g_diag_input_first_v;
static short g_diag_input_last_h, g_diag_input_last_v;
static long g_diag_input_downs, g_diag_input_ups;
static unsigned long g_diag_input_started;

/* The bit-16 script: hold at the press point for a beat, ramp to the
   baked target, dwell there, then report the button up. Ticks rather
   than sample counts, because the Manager's sampling rate is exactly
   what this experiment does not get to assume. */
enum {
    kScriptHoldTicks = 30,     /* 0.5 s at the press point   */
    kScriptRampTicks = 120,    /* 2 s of motion              */
    kScriptDwellTicks = 90,    /* 1.5 s at the target, held  */
    kScriptReleaseTicks = 60   /* 1 s reported button-up     */
};

static void script_sample(unsigned long elapsed, Point origin,
                          short *h, short *v, int *down)
{
    *down = 1;
    if (elapsed < (unsigned long)kScriptHoldTicks) {
        *h = origin.h;
        *v = origin.v;
        return;
    }
    elapsed -= (unsigned long)kScriptHoldTicks;
    if (elapsed < (unsigned long)kScriptRampTicks) {
        long span = (long)kScriptRampTicks;

        *h = (short)(origin.h
                     + ((long)(g_diag_script_h - origin.h) * (long)elapsed)
                       / span);
        *v = (short)(origin.v
                     + ((long)(g_diag_script_v - origin.v) * (long)elapsed)
                       / span);
        return;
    }
    *h = g_diag_script_h;
    *v = g_diag_script_v;
    elapsed -= (unsigned long)kScriptRampTicks;
    if (elapsed >= (unsigned long)kScriptDwellTicks) {
        *down = 0;
    }
}

static Point g_diag_input_origin;

static pascal OSErr diag_input(Point *mouse, SInt16 *modifiers, void *refcon,
                               DragRef drag)
{
    short h = 0, v = 0;
    int down = 0;
    unsigned long seq = 0;
    int have = 0;

    (void)refcon;
    (void)drag;

    g_diag_input_calls++;

    if ((g_diag_mask & 16) != 0) {
        script_sample((unsigned long)(TickCount() - g_diag_input_started),
                      g_diag_input_origin, &h, &v, &down);
        seq = (unsigned long)g_diag_input_calls;
        have = 1;
    } else {
        have = now_continuity_latest_input(&h, &v, &down, &seq);
    }

    if (!have) {
        /* Nothing to report is not the same as reporting nothing: leave
           the Manager's own sample alone and let it do what it would
           have done without us. */
        return noErr;
    }

    mouse->h = h;
    mouse->v = v;
    if (down) {
        *modifiers = (SInt16)(*modifiers & ~btnState);
        g_diag_input_downs++;
    } else {
        *modifiers = (SInt16)(*modifiers | btnState);
        g_diag_input_ups++;
    }

    if (g_diag_input_fed == 0) {
        g_diag_input_first_seq = seq;
        g_diag_input_first_h = h;
        g_diag_input_first_v = v;
    }
    g_diag_input_fed++;
    g_diag_input_last_seq = seq;
    g_diag_input_last_h = h;
    g_diag_input_last_v = v;
    return noErr;
}

/* The one drag item. The Drag Manager wants a reference number per item
   and this drag has exactly one, always: an offer holds one file (a
   folder is refused before we get here). */

/* How long the streaming promise waits with no progress at all before
   giving up on the Finder's behalf.

   The lane has its own 30-second silence timeout (wire.c) and it is the
   authority; this is a BACKSTOP against the case that timeout cannot
   see — a transfer that never started, because the ask was answered
   with nothing. Longer than the lane's own bound would be a second
   opinion; shorter would pre-empt it. Equal, plus a second of grace, is
   neither. */
enum { kPromiseStallTicks = 60 * 31 };

/* ------------------------------------------------------------------ */
/* Where the drop landed                                              */
/* ------------------------------------------------------------------ */

/* The drop location as a folder this machine can write into.

   GetDropLocation answers with an AEDesc — an alias, for a Finder
   window or the desktop. Coercing to typeFSS and then asking the
   catalogue for its directory ID is the whole of it; a drop somewhere
   that is not a folder (onto an application, say) yields no directory
   and is refused rather than guessed at. */
static Boolean drop_folder(DragRef drag, short *vref, long *dir)
{
    AEDesc drop;
    AEDesc as_fss;
    FSSpec spec;
    CInfoPBRec pb;
    Str255 name;
    Boolean ok = false;

    AECreateDesc(typeNull, NULL, 0, &drop);
    if (GetDropLocation(drag, &drop) != noErr) {
        AEDisposeDesc(&drop);
        return false;
    }
    if (drop.descriptorType == typeNull) {
        /* The Finder did not say where. Nothing to materialise into,
           and inventing the desktop here would put the file somewhere
           the person did not point at — which is the one thing this
           whole feature exists to get right. */
        AEDisposeDesc(&drop);
        return false;
    }
    if (AECoerceDesc(&drop, typeFSS, &as_fss) != noErr) {
        AEDisposeDesc(&drop);
        return false;
    }
    if (AEGetDescData(&as_fss, &spec, sizeof spec) == noErr) {
        memset(&pb, 0, sizeof pb);
        memcpy(name, spec.name, spec.name[0] + 1);
        pb.dirInfo.ioNamePtr = name;
        pb.dirInfo.ioVRefNum = spec.vRefNum;
        pb.dirInfo.ioDrDirID = spec.parID;
        pb.dirInfo.ioFDirIndex = 0;
        if (PBGetCatInfoSync(&pb) == noErr
            && (pb.dirInfo.ioFlAttrib & ioDirMask) != 0) {
            *vref = spec.vRefNum;
            *dir = pb.dirInfo.ioDrDirID;
            ok = true;
        }
    }
    AEDisposeDesc(&as_fss);
    AEDisposeDesc(&drop);
    return ok;
}

/* ------------------------------------------------------------------ */
/* The promise                                                        */
/* ------------------------------------------------------------------ */

/* Pull the offered bytes into `vref`/`dir` and put the file's own
   FSSpec in `out`. Runs INSIDE the Finder's drop handling.

   This is the named hazard of the whole slice. The Finder is sitting in
   a nested Toolbox loop waiting for this function to return; our main
   event loop is not running, so nothing is servicing the connection the
   bytes are arriving on. now_wire_pump() is called every pass here for
   exactly that reason, and now_continuity_pump() beside it because the
   cursor plane's lease is renewed on a different path from the wire's
   (see continuity_intake.c) and a drag whose cursor froze mid-drop is
   its own kind of broken.

   RULE FROM pump.h, and it binds hardest here: pumped code must never
   open a dialog. Every failure below sets a state and returns. */
static Boolean stream_promise(short vref, long dir, FSSpec *out)
{
    char err[96];
    long id = 0;
    long received = 0, expected = 0;
    long last_received = -1;
    unsigned long stall_deadline;
    WireGetPhase phase = kWireGetNone;
    Boolean landed;

    now_wire_get_destination(true, vref, dir);
    if (now_wire_get_offer(&id, err, sizeof err) != 0) {
        now_log(kLogWarn, "mirror", "drag promise refused before any byte: %s",
                err);
        now_wire_get_destination(false, 0, 0);
        return false;
    }

    stall_deadline = TickCount() + kPromiseStallTicks;
    for (;;) {
        now_wire_pump();
        now_continuity_pump();

        if (!now_wire_get_active(&received, &expected, &phase)) {
            break;
        }
        if (now_continuity_drag_should_abort(&g_drag)) {
            /* The only way into a nested Toolbox loop from outside it.
               Cancelling the pull as well as refusing the flavor
               matters: local-only would leave the host pushing into a
               lane nobody is reading. */
            now_wire_get_cancel(err, sizeof err);
            now_log(kLogInfo, "mirror", "drag promise cancelled at %ld of %ld bytes",
                    received, expected);
            now_wire_get_destination(false, 0, 0);
            return false;
        }
        if (received != last_received) {
            last_received = received;
            stall_deadline = TickCount() + kPromiseStallTicks;
        } else if (TickCount() > stall_deadline) {
            now_wire_get_cancel(err, sizeof err);
            now_log(kLogWarn, "mirror", "drag promise stalled at %ld of %ld bytes",
                    received, expected);
            now_wire_get_destination(false, 0, 0);
            return false;
        }
    }

    now_wire_get_destination(false, 0, 0);
    /* Matched against the id THIS call started. A transfer of ours that
       failed must never read back the file some earlier pull left
       behind and hand the Finder a stale file with total confidence. */
    landed = now_wire_get_landed(id, out);
    if (!landed) {
        char why[96];

        /* THE REFUSING CALL, BY NAME. Slice 0 could say only that the
           second same-name drop produced nothing; the layer that said
           no was never identified, and a verdict string of ours was
           read as the Finder's behaviour. */
        now_wire_get_last_failure(why, sizeof why);
        now_log(kLogWarn, "mirror", "drag promise #%ld did not land: %.60s",
                id, why[0] != '\0' ? why : "(no reason recorded)");
    }
    return landed;
}

/* DIAGNOSTIC. The FSSpec this drag handed the receiver, kept so that
   after TrackDrag returns we can ask the catalogue what the receiver
   DID with it — left it where we put it, moved it, renamed it, or threw
   it away. That answer is the whole "who owns the destination"
   question, and it cannot be asked from inside the drop. */
static FSSpec g_diag_promise_spec;
static Boolean g_diag_promise_spec_valid;

static pascal OSErr drag_send_data(FlavorType type, void *refcon,
                                   DragItemRef item, DragRef drag)
{
    FSSpec spec;
    short vref;
    long dir;

    (void)refcon;

    /* LOGGED BEFORE ANY DECISION THAT COULD HIDE IT, and the flavor is
       named. `promise-never-asked` is a verdict derived from state, and
       state can only say the callback did not COMPLETE - two of the
       returns below leave no trace in it at all. So the arrival itself
       is recorded here, unconditionally, where nothing can swallow it.

       Which flavor is the useful half: a receiver asking for something
       other than the promised one is a different defect from a receiver
       that never asks, and until this line the two were one word. */
    now_log(kLogInfo, "mirror", "drag promise asked for '%.4s'",
            (const char *)&type);

    /* DIAGNOSTIC. Which side of TrackDrag's return the ask arrived on is
       the question bit 1 exists to answer, and it can only be recorded
       here — afterwards, both look identical. */
    g_diag_asks++;
    if (!g_diag_tracking) {
        g_diag_late_asks++;
        now_log(kLogWarn, "mirror",
                "drag promise asked AFTER TrackDrag returned");
    }

    /* The only flavor promised. Anything else is a receiver asking for
       something this drag never offered. */
    if (type != kDragPromisedFlavor) {
        return badDragFlavorErr;
    }
    if (!now_continuity_drag_promise_begin(&g_drag)) {
        /* Cancelled between the drop and this callback, or no drag of
           ours is running. Refusing the flavor ends the drag cleanly,
           which is the point: the alternative is streaming a file
           nobody is still asking for. */
        return cantGetFlavorErr;
    }
    if (!drop_folder(drag, &vref, &dir)) {
        now_continuity_drag_promise_end(&g_drag, 0);
        return cantGetFlavorErr;
    }

    /* ---- SLICE-2 DIAGNOSTIC BIT 32: WHOSE FOLDER PLACES THE FILE ----
       Measured 2026-08-17: materialising into the folder the receiver
       named leaves the file exactly where we put it, under the name we
       chose — the receiver never touches it, so its own duplicate
       machinery never runs and a second same-name drop dies in OUR
       pre-check. This bit asks the other half of the question: given a
       file that is NOT already at its destination, does the receiver
       move it there itself? If it does, the placement — and every
       collision decision that comes with it — was always the
       receiver's, and the send proc has no business naming a
       destination at all. */
    if ((g_diag_mask & 32) != 0) {
        short tvref = 0;
        long tdir = 0;

        if (FindFolder(vref, kTemporaryFolderType, kCreateFolder,
                       &tvref, &tdir) == noErr) {
            FSSpec stale;
            Str255 pname;

            /* Our own scratch, our own leftovers: a previous drop's
               staged copy is ours to clear, and clearing it is not a
               decision about anybody's file. */
            CopyCStringToPascal(g_drag.item.name, pname);
            if (FSMakeFSSpec(tvref, tdir, pname, &stale) == noErr) {
                FSpDelete(&stale);
            }
            vref = tvref;
            dir = tdir;
            now_log(kLogInfo, "mirror",
                    "drag promise staging in Temporary Items (dir %ld)",
                    tdir);
        } else {
            now_log(kLogWarn, "mirror",
                    "drag promise: no Temporary Items folder; using the "
                    "drop folder");
        }
    }
    now_log(kLogInfo, "mirror", "drag promise streaming %.31s into dir %ld",
            g_drag.item.name, dir);
    /* WHOSE FOLDER THE RECEIVER NAMED, and whether the name it is about
       to be handed is already taken there. Both are facts about the
       RECEIVER's house, and the collision diagnosis cannot proceed
       without them: a staging folder the Finder empties afterwards and
       the final destination itself are different protocols wearing the
       same directory id. */
    {
        char path[192];
        FSSpec probe;
        Str255 pname;
        OSErr taken;

        if (now_files_dir_path(vref, dir, path, sizeof path) != kFilesOK) {
            snprintf(path, sizeof path, "(dir %ld, path unresolved)", dir);
        }
        CopyCStringToPascal(g_drag.item.name, pname);
        taken = FSMakeFSSpec(vref, dir, pname, &probe);
        now_log(kLogInfo, "mirror", "drag promise dest: %.60s", path);
        now_log(kLogInfo, "mirror",
                "drag promise name check: FSMakeFSSpec('%.31s') -> %d "
                "(0 = already there)", g_drag.item.name, (int)taken);
    }
    if (!stream_promise(vref, dir, &spec)) {
        now_continuity_drag_promise_end(&g_drag, 0);
        return cantGetFlavorErr;
    }
    /* The file exists, whole, at the place the person dropped it. The
       Finder positions it from here. */
    g_diag_promise_spec = spec;
    g_diag_promise_spec_valid = true;
    if (SetDragItemFlavorData(drag, item, kDragPromisedFlavor, &spec,
                              (Size)sizeof spec, 0) != noErr) {
        now_continuity_drag_promise_end(&g_drag, 0);
        return cantGetFlavorErr;
    }
    now_continuity_drag_promise_end(&g_drag, 1);
    return noErr;
}

/* ------------------------------------------------------------------ */
/* What the drag looks like                                           */
/* ------------------------------------------------------------------ */

enum {
    kDragIconSize = 32,
    kDragNameGap = 2,
    kDragNameHeight = 14,
    kDragImageWidth = 96
};

/* The item's rectangle in global coordinates, centred under the cursor
   where a person's own drag would have picked it up. */
static void drag_bounds(Point where, Rect *r)
{
    r->left = (short)(where.h - kDragImageWidth / 2);
    r->top = (short)(where.v - kDragIconSize / 2);
    r->right = (short)(r->left + kDragImageWidth);
    r->bottom = (short)(r->top + kDragIconSize + kDragNameGap
                        + kDragNameHeight);
}

/* Draw the offer's own icon and name into an offscreen world, so the
   thing crossing the screen is the file the person picked up rather
   than a grey rectangle.

   THE ICON COMES FROM THE IDENTITY, not from the file — there is no
   file yet, which is the whole point of a promise. GetIconRef on the
   type/creator pair is what a listing off the wire can support and is
   already proven on this machine (docs/guest-ui-start-here.md).

   Returns NULL when anything is unavailable, and the caller then drags
   the outline alone. A drag with no picture is a lesser drag; a drag
   that failed to start because an icon was missing is a broken one.

   RETURNS WITH ITS PIXELS LOCKED, and the caller unlocks only after
   TrackDrag has returned. The Drag Manager holds this PixMap and reads
   it on every tracking pass for the whole life of the drag, so the lock
   has to outlive drawing into it — an unlocked GWorld's baseAddr is the
   Memory Manager's to move or purge, and the picture crossing the
   screen would be whatever landed there instead. Every other GWorld in
   this tree (screenshots/pixels.c, screenshots/capture.c) holds its
   lock across exactly the span the pixels are read, which is the same
   rule stated by a different caller. */
static GWorldPtr build_drag_image(const Rect *bounds)
{
    GWorldPtr world = NULL;
    GWorldPtr save_port;
    GDHandle save_device;
    Rect local;
    Rect icon_rect;
    IconRef icon = NULL;
    Str255 pname;
    OSType type, creator;

    local = *bounds;
    OffsetRect(&local, (short)-local.left, (short)-local.top);
    if (NewGWorld(&world, 8, &local, NULL, NULL, 0) != noErr
        || world == NULL) {
        return NULL;
    }
    GetGWorld(&save_port, &save_device);
    SetGWorld(world, NULL);
    if (!LockPixels(GetGWorldPixMap(world))) {
        SetGWorld(save_port, save_device);
        DisposeGWorld(world);
        return NULL;
    }

    /* White ground: the drag image is masked by the drag region, so
       what is not drawn is not shown. */
    EraseRect(&local);

    type = g_drag.item.have_file_type ? (OSType)g_drag.item.file_type
                                      : (OSType)'????';
    creator = g_drag.item.have_creator ? (OSType)g_drag.item.creator
                                       : (OSType)'????';
    icon_rect.left = (short)((local.right - kDragIconSize) / 2);
    icon_rect.top = local.top;
    icon_rect.right = (short)(icon_rect.left + kDragIconSize);
    icon_rect.bottom = (short)(icon_rect.top + kDragIconSize);
    if (GetIconRef(kOnSystemDisk, creator, type, &icon) == noErr
        && icon != NULL) {
        PlotIconRef(&icon_rect, kAlignAbsoluteCenter, kTransformNone,
                    kIconServicesNormalUsageFlag, icon);
        ReleaseIconRef(icon);
    }

    /* MacRoman, always — the name crossed the wire already mapped (the
       contract's naming policy), and DrawString cannot hold anything
       else. */
    TextFont(applFont);
    TextSize(9);
    CopyCStringToPascal(g_drag.item.name, pname);
    if (pname[0] > 0) {
        short width = StringWidth(pname);

        MoveTo((short)((local.right - width) / 2),
               (short)(icon_rect.bottom + kDragNameGap + 10));
        DrawString(pname);
    }

    /* Deliberately still locked; see the header comment. */
    SetGWorld(save_port, save_device);
    return world;
}

/* ------------------------------------------------------------------ */
/* Starting the real drag                                             */
/* ------------------------------------------------------------------ */

static DragSendDataUPP send_upp(void)
{
    if (g_send_upp == NULL) {
        /* A UPP IS NOT A CAST on this runtime. This build is
           TARGET_RT_MAC_CFM, where a UPP is a routine descriptor, and
           handing the Toolbox a bare function pointer is a Type 3 the
           first time it calls back. Finding:
           carbon-upp-is-not-a-cast-on-cfm. */
        g_send_upp = NewDragSendDataUPP(drag_send_data);
    }
    return g_send_upp;
}

static void start_drag(void)
{
    DragRef drag = NULL;
    PromiseHFSFlavor promise;
    EventRecord event;
    RgnHandle region;
    Rect bounds;
    Point where;
    GWorldPtr image;
    Str255 pname;
    unsigned long started = TickCount();
    DragSendDataUPP upp = send_upp();

    if (upp == NULL) {
        now_log(kLogError, "mirror", "drag: no send-data UPP; not started");
        now_continuity_drag_start_failed(&g_drag);
        return;
    }
    if ((g_diag_mask & 4) != 0) {
        diag_install_handlers();
    }
    if (NewDrag(&drag) != noErr || drag == NULL) {
        now_log(kLogError, "mirror", "drag: NewDrag refused");
        now_continuity_drag_start_failed(&g_drag);
        return;
    }
    if (SetDragSendProc(drag, upp, NULL) != noErr) {
        DisposeDrag(drag);
        now_continuity_drag_start_failed(&g_drag);
        return;
    }

    /* The promise itself. promisedFlavor names the flavor that will
       carry an FSSpec when somebody asks for it — kDragPromisedFlavor
       is the value for everything that is not Find File. */
    memset(&promise, 0, sizeof promise);
    promise.fileType = g_drag.item.have_file_type
        ? (OSType)g_drag.item.file_type : (OSType)'????';
    promise.fileCreator = g_drag.item.have_creator
        ? (OSType)g_drag.item.creator : (OSType)'????';
    promise.fdFlags = 0;
    promise.promisedFlavor = kDragPromisedFlavor;
    if (AddDragItemFlavor(drag, kOfferItemRef, flavorTypePromiseHFS,
                          &promise, (Size)sizeof promise,
                          flavorNotSaved) != noErr) {
        DisposeDrag(drag);
        now_continuity_drag_start_failed(&g_drag);
        return;
    }
    /* Declared with no data: the send-data callback fills it in on
       demand, which is what makes this a promise rather than a file.

       ITS RESULT IS CHECKED, unlike the first version of this line. This
       is the flavor the receiver asks for, so a failure here is a drag
       that can never be completed by anybody - and it would present as
       the receiver simply never asking, which is indistinguishable from
       a Finder that does not speak promised HFS. Refusing to start is
       the honest answer to a promise we could not declare. */
    if (AddDragItemFlavor(drag, kOfferItemRef, kDragPromisedFlavor, NULL, 0,
                          flavorNotSaved) != noErr) {
        now_log(kLogError, "mirror",
                "drag: the promised flavor would not attach; not started");
        DisposeDrag(drag);
        now_continuity_drag_start_failed(&g_drag);
        return;
    }
    /* The name the Finder should use, offered as a hint rather than
       imposed — the receiver remains free to uniquify it. */
    CopyCStringToPascal(g_drag.item.name, pname);
    if (pname[0] > 0 && (g_diag_mask & 2) == 0) {
        AddDragItemFlavor(drag, kOfferItemRef, kFlavorTypeClippingName,
                          &pname[1], (Size)pname[0], 0);
    }

    /* SLICE-0 ROUTE A'. Attached before the bounds are taken so the
       origin the script ramps from is the same point the drag image is
       built around. A refusal is LOUD and not fatal: a drag that ran
       without the proc would otherwise answer the experiment's question
       with the old wall's answer and look like a result. */
    if ((g_diag_mask & 24) != 0) {
        if (g_diag_input_upp == NULL) {
            /* A UPP IS NOT A CAST on this runtime; same rule as the
               send proc above. */
            g_diag_input_upp = NewDragInputUPP(diag_input);
        }
        g_diag_input_calls = 0;
        g_diag_input_fed = 0;
        g_diag_input_downs = 0;
        g_diag_input_ups = 0;
        g_diag_input_first_seq = 0;
        g_diag_input_last_seq = 0;
        if (g_diag_input_upp == NULL
            || SetDragInputProc(drag, g_diag_input_upp, NULL) != noErr) {
            now_log(kLogError, "mirror",
                    "drag input: SetDragInputProc REFUSED; not Route A'");
        } else {
            now_log(kLogInfo, "mirror",
                    "drag input: proc attached (mask=%ld target=%d,%d)",
                    g_diag_mask, (int)g_diag_script_h, (int)g_diag_script_v);
        }
    }

    GetMouse(&where);
    LocalToGlobal(&where);
    g_diag_input_origin = where;
    g_diag_input_started = TickCount();
    drag_bounds(where, &bounds);
    SetDragItemBounds(drag, kOfferItemRef, &bounds);

    region = NewRgn();
    if (region != NULL) {
        RectRgn(region, &bounds);
    }
    image = build_drag_image(&bounds);
    if (image != NULL && region != NULL) {
        Point offset;
        OSErr set;

        offset.h = bounds.left;
        offset.v = bounds.top;
        set = SetDragImage(drag, GetGWorldPixMap(image), region, offset,
                           kDragRegionAndImage);
        /* Reported rather than ignored: a drag that crosses the screen
           as a bare outline and one that carries the file's icon look
           different to a person and identical in a log, and the whole
           point of the identity crossing early is that the picture is
           right before any byte moves. Not fatal — the outline alone is
           still a drag. */
        if (set != noErr) {
            now_log(kLogWarn, "mirror",
                    "drag image refused (%d); dragging the outline alone",
                    (int)set);
        }
    } else {
        now_log(kLogWarn, "mirror",
                "drag has no image; dragging the outline alone");
    }

    /* The EventRecord the Drag Manager tracks from. The button under it
       is the SYNTHETIC one the resident applied — this whole path only
       runs because now_continuity_button_is_down() said so — and the
       modifiers are the host's live word rather than this machine's,
       for the same reason. */
    event.what = mouseDown;
    event.message = 0;
    event.when = TickCount();
    event.where = where;
    event.modifiers = (short)now_continuity_host_modifiers();

    now_log(kLogInfo, "mirror", "drag tracking %.31s (%ld bytes)",
            g_drag.item.name, g_drag.item.data_size);

    /* WHAT THE DRAG MANAGER SAYS IT IS HOLDING, read back rather than
       assumed from three noErr returns. AddDragItemFlavor answering
       noErr and the drag actually carrying that flavor are two claims,
       and only the second is the one a receiver acts on. */
    {
        UInt16 items = 0, flavors = 0, i;
        char list[64];
        long used = 0;

        CountDragItems(drag, &items);
        CountDragItemFlavors(drag, kOfferItemRef, &flavors);
        list[0] = '\0';
        for (i = 1; i <= flavors && used + 6 < (long)sizeof list; i++) {
            FlavorType ft = 0;

            if (GetFlavorType(drag, kOfferItemRef, i, &ft) != noErr) {
                break;
            }
            used += snprintf(list + used, sizeof list - used, "%s'%.4s'",
                             used > 0 ? " " : "", (const char *)&ft);
        }
        now_log(kLogInfo, "mirror", "drag carries: items=%u flavors=%u %s",
                (unsigned)items, (unsigned)flavors, list);
    }

    /* THE WIRE STOPS HERE, and that is documented rather than fixed:
       TrackDrag takes no idle callback, exactly like MenuSelect and
       DragWindow in pump.h's list of what cannot be pumped. The
       difference — and the reason the promise callback pumps by hand —
       is that the drop INSIDE this call is where bytes have to move. */
    {
        /* TWO ARTIFACTS, ONE QUESTION, ASKED SEPARATELY.
           `plane` is the resident's applied button — the one the arm
           ripened on. `toolbox` is Button(), this Macintosh's own, and
           it is the one TrackDrag actually tracks. They are sampled
           HERE rather than at the tick that decided to start, because
           everything between the two (NewDrag, three flavors, an
           offscreen world with an icon plotted into it) costs ticks a
           synthetic button can expire inside. `setup` is that cost,
           reported rather than assumed. */
        int plane = now_continuity_button_is_down() ? 1 : 0;
        int toolbox = Button() ? 1 : 0;
        unsigned long entered = TickCount();
        OSErr track;
        int verdict;

        g_diag_asks = 0;
        g_diag_late_asks = 0;
        g_diag_tracking = true;
        track = TrackDrag(drag, &event, region);
        g_diag_tracking = false;
        verdict = now_continuity_drag_ended(&g_drag, track == noErr,
                                            toolbox);

        /* TWO LINES, NOT ONE, AND THE SPLIT IS LOAD-BEARING. nowlog.c
           formats the body with "%.99s", so a body longer than 99
           characters loses its tail SILENTLY. The first version of this
           was one line and the live guest logged

               ... (TrackDrag -128) button plane=1 toolbox=1 at

           - every measured fact after "at" cut off, with nothing saying
           so. An instrument whose reading is truncated reports the
           absence of the reading and the absence of the thing in the
           same words, which is the failure this whole line exists to
           end. Both bodies below are well inside the cap. */
        now_log(track == noErr && verdict == kNowDragOK
                    ? kLogInfo : kLogWarn,
                "mirror", "drag %.31s ended: %s (TrackDrag %d)",
                g_drag.item.name, now_continuity_drag_code(verdict),
                (int)track);
        /* WHAT THE RECEIVER DID WITH THE FILE WE HANDED IT. Asked of
           the catalogue, once, after the drop is over: still at the
           spec we returned means the receiver accepted our placement
           and owns nothing; gone means it moved or renamed it, and the
           destination is the receiver's after all. */
        if (g_diag_promise_spec_valid) {
            FSSpec after;
            char shown[32];
            OSErr still = FSMakeFSSpec(g_diag_promise_spec.vRefNum,
                                       g_diag_promise_spec.parID,
                                       g_diag_promise_spec.name, &after);

            /* A Str255 is not a C string; printing its body directly
               runs off the end of the name into whatever follows. */
            CopyPascalStringToC(g_diag_promise_spec.name, shown);
            now_log(kLogInfo, "mirror",
                    "drag promise after: '%.31s' in dir %ld -> %d "
                    "(0 = still where we put it)",
                    shown, g_diag_promise_spec.parID, (int)still);
            g_diag_promise_spec_valid = false;
        }
        now_log(kLogInfo, "mirror",
                "drag detail: button plane=%d toolbox=%d at %d,%d "
                "setup=%lu track=%lu ticks",
                plane, toolbox, (int)where.h, (int)where.v,
                (unsigned long)(entered - started),
                (unsigned long)(TickCount() - entered));

        /* WHERE THE DROP LANDED, ASKED OF THE DRAG ITSELF.
           `promise-never-asked` says the callback did not run; it cannot
           say whether anybody was there to run it. A receiver that took
           the drop calls SetDropLocation on its way through, so the
           descriptor type here separates "the Finder had it and declined
           to ask" from "nothing ever received this at all" - two
           diagnoses that have shared one sentence for this whole slice.
           typeNull means nobody set one. */
        {
            AEDesc drop;
            OSType kind = typeNull;
            OSErr loc_err;
            Point endp;
            DragAttributes attrs = 0;

            AECreateDesc(typeNull, NULL, 0, &drop);
            loc_err = GetDropLocation(drag, &drop);
            if (loc_err == noErr) {
                kind = drop.descriptorType;
            }
            AEDisposeDesc(&drop);
            GetMouse(&endp);
            LocalToGlobal(&endp);
            now_log(kLogInfo, "mirror",
                    "drag drop: loc='%.4s' err=%d end=%d,%d mods=0x%04x "
                    "asks=%ld",
                    (const char *)&kind, (int)loc_err,
                    (int)endp.h, (int)endp.v,
                    (unsigned)event.modifiers, g_diag_asks);

            /* WHETHER THE DRAG EVER LEFT US, asked of the Drag Manager
               rather than inferred from coordinates. A drop location of
               typeNull says no receiver claimed the drop; it cannot say
               whether the drag was ever OFFERED to one. These three bits
               can:

                 left   the drag left the sender WINDOW at some point
                 inapp  it ended inside the sender APPLICATION
                 inwin  it ended inside the sender window

               `left=0` means the Drag Manager never considered this drag
               to have gone anywhere - a different defect from a Finder
               that saw it and declined. Reading the pointer's final
               coordinates off a screen capture answers neither, and that
               is how this slice has been reasoning so far. */
            GetDragAttributes(drag, &attrs);
            now_log(kLogInfo, "mirror",
                    "drag attrs: 0x%08lx left=%d inapp=%d inwin=%d",
                    (unsigned long)attrs,
                    (attrs & kDragHasLeftSenderWindow) ? 1 : 0,
                    (attrs & kDragInsideSenderApplication) ? 1 : 0,
                    (attrs & kDragInsideSenderWindow) ? 1 : 0);
            if ((g_diag_mask & 4) != 0) {
                now_log(kLogInfo, "mirror",
                        "drag ctrl: tracking messages seen = %ld",
                        g_diag_track_msgs);
            }
            /* THE INPUT PROC'S OWN READING, and it is three separate
               questions asked in three separate fields, because they
               have three different cures.

                 calls  the Manager sampled us at all. Zero says
                        SetDragInputProc is not the seam we think it is
                        on this system, and nothing else here matters.
                 fed    we had a sample to give. calls>0 with fed=0 is a
                        LIVE plane question, not a Manager question.
                 seq    the plane's own position sequence, first and
                        last. Equal seq across a whole drag is a plane
                        that froze inside TrackDrag - the 2026-08-17
                        wall in a different costume - and is exactly
                        what bit 16's script exists to rule out.

               Two lines: nowlog truncates a body at 99 characters and
               the tail is where the coordinates are. */
            if ((g_diag_mask & 24) != 0) {
                now_log(kLogInfo, "mirror",
                        "drag input: calls=%ld fed=%ld down=%ld up=%ld",
                        g_diag_input_calls, g_diag_input_fed,
                        g_diag_input_downs, g_diag_input_ups);
                now_log(kLogInfo, "mirror",
                        "drag input: seq %lu..%lu pt %d,%d..%d,%d",
                        g_diag_input_first_seq, g_diag_input_last_seq,
                        (int)g_diag_input_first_h, (int)g_diag_input_first_v,
                        (int)g_diag_input_last_h, (int)g_diag_input_last_v);
            }
        }
    }

    /* Torn down in every case, including the failures above: classic
       Finder is unforgiving of a drag that never ends, and a DragRef
       leaked here is a drag that never does. */
    DisposeDrag(drag);
    if (region != NULL) {
        DisposeRgn(region);
    }
    if (image != NULL) {
        /* Paired with the lock build_drag_image deliberately left held
           for the drag's whole life. Unlocked before disposal so the
           Memory Manager gets an ordinary block back. */
        UnlockPixels(GetGWorldPixMap(image));
        DisposeGWorld(image);
    }
}

/* ------------------------------------------------------------------ */
/* The faces                                                          */
/* ------------------------------------------------------------------ */

int now_continuity_dragmgr_request(char *err, long cap)
{
    const NowContinuityOfferTable *offer = now_continuity_offer_table();
    int verdict = now_continuity_drag_request(&g_drag, offer,
                                              now_continuity_live_epoch(),
                                              TickCount());

    if (verdict == kNowDragOK) {
        now_log(kLogInfo, "mirror", "drag armed for %.31s; waiting on the button",
                g_drag.item.name);
        return 0;
    }
    switch (verdict) {
    case kNowDragNoOffer:
        snprintf(err, (size_t)cap, "Nothing is being held out right now");
        break;
    case kNowDragFolder:
        snprintf(err, (size_t)cap,
                 "That is a folder; this Mac cannot drag one yet");
        break;
    case kNowDragTooLarge:
        /* THE SIZE COMES FROM THE OFFER, NOT FROM g_drag. A refusal
           deliberately leaves the drag state untouched - that is what
           lets `busy` refuse without trampling a drag in flight - so
           g_drag.item is either empty or somebody else's. The first
           live emulator run said "0 bytes; the limit is 1048576" for a
           1048577-byte file, which is a refusal that argues against
           itself. */
        snprintf(err, (size_t)cap,
                 "Too big to hand over inside a drop (%ld bytes; the "
                 "limit is %ld)",
                 offer->item.data_size,
                 (long)kNowContinuityDragPromiseCapBytes);
        break;
    case kNowDragBusy:
        snprintf(err, (size_t)cap, "A drag is already under way");
        break;
    default:
        snprintf(err, (size_t)cap, "%s",
                 now_continuity_drag_code(verdict));
        break;
    }
    return -1;
}

int now_continuity_dragmgr_cancel(char *err, long cap)
{
    if (now_continuity_drag_cancel(&g_drag) != kNowDragOK) {
        snprintf(err, (size_t)cap, "No drag to stop");
        return -1;
    }
    now_log(kLogInfo, "mirror", "drag cancel asked (%s)",
            now_continuity_drag_state_name(g_drag.state));
    return 0;
}

void now_continuity_dragmgr_service(void)
{
    int action;

    if (g_drag.state != kNowDragWaitingButton) {
        return;
    }
    action = now_continuity_drag_tick(&g_drag,
                                      now_continuity_button_is_down(),
                                      TickCount());
    if (action == kNowDragTickStart) {
        start_drag();
    } else if (action == kNowDragTickExpire) {
        now_log(kLogWarn, "mirror", "drag arm expired: %s",
                now_continuity_drag_code(g_drag.last_verdict));
    }
}

void now_continuity_dragmgr_status(const char **state, const char **verdict)
{
    if (state != NULL) {
        *state = now_continuity_drag_state_name(g_drag.state);
    }
    if (verdict != NULL) {
        *verdict = now_continuity_drag_code(g_drag.last_verdict);
    }
}

Boolean now_continuity_dragmgr_busy(void)
{
    return g_drag.state != kNowDragIdle;
}

void now_continuity_dragmgr_forget(void)
{
    now_continuity_drag_forget(&g_drag);
}

void now_continuity_dragmgr_shutdown(void)
{
    if (g_send_upp != NULL) {
        DisposeDragSendDataUPP(g_send_upp);
        g_send_upp = NULL;
    }
    if (g_diag_input_upp != NULL) {
        DisposeDragInputUPP(g_diag_input_upp);
        g_diag_input_upp = NULL;
    }
}
