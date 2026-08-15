#include "workshop_drop.h"

#include <Drag.h>

#include <stdio.h>
#include <string.h>

#include "nowlog.h"
#include "wire.h"

enum {
    /* Deep enough for a Finder selection someone would plausibly drag in
       one gesture, shallow enough that the queue is a fixed-size array in
       a 6 MB partition. A drop past the cap is REPORTED (see g_dropped)
       rather than truncated in silence - a send that never happened and
       said nothing is the failure this whole file is written against. */
    kDropQueueCap = 32
};

static WindowRef g_window;
static DragTrackingHandlerUPP g_track_upp;
static DragReceiveHandlerUPP g_receive_upp;
static Boolean g_installed;
static Boolean g_available;
static Boolean g_asked_gestalt;
static Boolean g_hilited;

static FSSpec g_queue[kDropQueueCap];
static short g_head;
static short g_count;
static short g_dropped;            /* items the cap refused, since the note */
static char g_note[128];

/* ---------------------------------------------------------------- gate */

Boolean now_drop_available(void)
{
    long attr = 0;

    if (!g_asked_gestalt) {
        g_asked_gestalt = true;
        /* Gestalt failure is absence, not an error to report: a Mac
           without the Drag Manager is a Mac where this feature does not
           exist, and the Files page's Send button still does. */
        g_available = (Boolean)(Gestalt(gestaltDragMgrAttr, &attr) == noErr
                                && (attr & (1L << gestaltDragMgrPresent)) != 0);
    }
    return g_available;
}

/* -------------------------------------------------------------- queue */

static Boolean enqueue(const FSSpec *spec)
{
    short slot;

    if (g_count >= kDropQueueCap) {
        ++g_dropped;
        return false;
    }
    slot = (short)((g_head + g_count) % kDropQueueCap);
    g_queue[slot] = *spec;
    ++g_count;
    /* A fresh gesture retires the last one's refusal: the sentence in
       the placard should be about the files in hand. */
    g_note[0] = '\0';
    return true;
}

/* A dragged FOLDER or DISK arrives as an ordinary HFS flavor - the
   Drag Manager's pseudo type/creator ('fold'/'disk' with 'MACS') is a
   convention the SENDER fills in, and this asks the file system rather
   than trusting it. `now_wire_send_file` sends one file's forks; there
   is no recursive send on this wire yet, so a folder is refused with
   the reason rather than sent as whatever its directory record looks
   like. */
static Boolean spec_is_folder(const FSSpec *spec)
{
    CInfoPBRec pb;
    Str255 name;

    memset(&pb, 0, sizeof pb);
    memcpy(name, spec->name, (size_t)spec->name[0] + 1);
    pb.hFileInfo.ioNamePtr = name;
    pb.hFileInfo.ioVRefNum = spec->vRefNum;
    pb.hFileInfo.ioDirID = spec->parID;
    pb.hFileInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) != noErr) {
        return false;                 /* let the send report the real error */
    }
    return (Boolean)((pb.hFileInfo.ioFlAttrib & ioDirMask) != 0);
}

/* Bounded by construction rather than by an FSSpec's Str63 happening to
   fit whatever the caller passed. */
static void spec_name(const FSSpec *spec, char *out, long cap)
{
    long len = spec->name[0];

    if (cap <= 0) {
        return;
    }
    if (len > cap - 1) {
        len = cap - 1;
    }
    memcpy(out, spec->name + 1, (size_t)len);
    out[len] = '\0';
}

void now_drop_idle(void)
{
    FSSpec spec;
    char name[64];
    char why[128];

    if (g_dropped > 0) {
        snprintf(g_note, sizeof g_note,
                 "%d file(s) were not taken: only %d can wait at once.",
                 (int)g_dropped, (int)kDropQueueCap);
        g_dropped = 0;
        return;
    }
    if (g_count == 0) {
        return;
    }
    /* HELD, NOT DISCARDED. A drop with no session is not a mistake the
       person made - the files stay queued, and now_drop_status says
       exactly why nothing is moving, which is the difference between
       waiting and a drop that vanished. */
    if (!conn_is_connected()) {
        return;
    }
    /* One offer at a time is the wire's shape, not a choice made here;
       files_share_view greys its Send button on the same reading. */
    if (now_wire_send_state(NULL, NULL, NULL, 0) != kSendNothing) {
        return;
    }
    spec = g_queue[g_head];
    g_head = (short)((g_head + 1) % kDropQueueCap);
    --g_count;
    spec_name(&spec, name, sizeof name);
    if (spec_is_folder(&spec)) {
        snprintf(g_note, sizeof g_note,
                 "\"%.31s\" is a folder. Send the files inside it.", name);
        return;
    }
    if (now_wire_send_file(&spec, why, sizeof why) < 0) {
        snprintf(g_note, sizeof g_note, "%.110s", why);
        return;
    }
    /* HANDED OVER, so this line stops talking. Once the wire has the
       file, the Files page's own status - which the wire narrates
       through conn_set_file_note - is a better sentence than anything
       this queue could write, and a "Sending X" left standing here would
       cover it for the whole transfer and stay after it finished.
       What remains is only what the page cannot know: how many are
       still behind this one, and now_drop_status says that. */
    g_note[0] = '\0';
}

/* Precedence, and it is deliberately narrow. A refusal or a wait is
   something no page can explain, so it comes first; a queue still
   holding files is a fact no page has; and anything else is the page's
   own business, which this yields to by answering "". */
void now_drop_status(char *out, long cap)
{
    if (cap <= 0) {
        return;
    }
    if (g_note[0] != '\0') {
        snprintf(out, (size_t)cap, "%s", g_note);
        return;
    }
    if (g_count > 0) {
        if (!conn_is_connected()) {
            snprintf(out, (size_t)cap,
                     "Not connected: %d file(s) waiting to send.",
                     (int)g_count);
        } else {
            snprintf(out, (size_t)cap, "%d more file(s) to send.",
                     (int)g_count);
        }
        return;
    }
    out[0] = '\0';
}

void now_drop_clear_note(void)
{
    g_note[0] = '\0';
}

/* -------------------------------------------------------- drag handlers */

/* True when this drag carries at least one HFS flavor. Asked at
   kDragTrackingEnterWindow so the hilite is a promise: highlighting for
   a drag this application would then refuse is worse than not
   highlighting at all. */
static Boolean drag_has_files(DragRef drag)
{
    UInt16 items = 0;
    UInt16 i;

    if (CountDragItems(drag, &items) != noErr) {
        return false;
    }
    for (i = 1; i <= items; ++i) {
        DragItemRef item = 0;
        FlavorFlags flags = 0;

        if (GetDragItemReferenceNumber(drag, i, &item) != noErr) {
            continue;
        }
        if (GetFlavorFlags(drag, item, flavorTypeHFS, &flags) == noErr) {
            return true;
        }
    }
    return false;
}

/* The content region, in the window's own coordinates, which is what
   ShowDragHilite frames. The whole content is the target rather than one
   page's rectangle: a file dropped on NOW means "send this", and that is
   true wherever in the window the person let go. */
static void hilite_region(WindowRef window, RgnHandle region)
{
    Rect content;

    GetWindowPortBounds(window, &content);
    RectRgn(region, &content);
}

static void show_hilite(WindowRef window, DragRef drag)
{
    GrafPtr saved;
    RgnHandle region;

    if (g_hilited) {
        return;
    }
    region = NewRgn();
    if (region == NULL) {
        return;
    }
    GetPort(&saved);
    SetPortWindowPort(window);
    hilite_region(window, region);
    if (ShowDragHilite(drag, region, true) == noErr) {
        g_hilited = true;
    }
    SetPort(saved);
    DisposeRgn(region);
}

static void hide_hilite(WindowRef window, DragRef drag)
{
    GrafPtr saved;

    if (!g_hilited) {
        return;
    }
    g_hilited = false;
    GetPort(&saved);
    SetPortWindowPort(window);
    HideDragHilite(drag);
    SetPort(saved);
}

static pascal OSErr track_drag(DragTrackingMessage message, WindowRef window,
                               void *refcon, DragRef drag)
{
    (void)refcon;
    if (window == NULL || window != g_window) {
        return noErr;
    }
    switch (message) {
    case kDragTrackingEnterWindow:
        if (drag_has_files(drag)) {
            show_hilite(window, drag);
        }
        break;
    case kDragTrackingLeaveWindow:
        hide_hilite(window, drag);
        break;
    default:
        /* kDragTrackingInWindow deliberately does nothing. The hilite is
           the whole content region, so there is no sub-target to move it
           between, and redrawing it per mouse-move is the flicker loop
           docs/guest-ui-start-here.md names three times over. */
        break;
    }
    return noErr;
}

/* Copies every HFS flavor into the queue and returns. It does NOT send:
   this runs inside the drag's tracking loop (workshop_drop.h says why),
   and the queue is drained from the application's own event loop one
   pass later. */
static pascal OSErr receive_drop(WindowRef window, void *refcon, DragRef drag)
{
    UInt16 items = 0;
    UInt16 i;
    short taken = 0;

    (void)refcon;
    if (window == NULL || window != g_window) {
        return dragNotAcceptedErr;
    }
    hide_hilite(window, drag);
    if (CountDragItems(drag, &items) != noErr) {
        return dragNotAcceptedErr;
    }
    for (i = 1; i <= items; ++i) {
        DragItemRef item = 0;
        HFSFlavor flavor;
        Size size = (Size)sizeof flavor;

        if (GetDragItemReferenceNumber(drag, i, &item) != noErr) {
            continue;
        }
        memset(&flavor, 0, sizeof flavor);
        if (GetFlavorData(drag, item, flavorTypeHFS, &flavor, &size, 0)
                != noErr) {
            continue;
        }
        /* A short answer is a flavor this application does not
           understand, not an FSSpec to guess at. */
        if (size < (Size)sizeof flavor) {
            continue;
        }
        if (enqueue(&flavor.fileSpec)) {
            ++taken;
        }
    }
    if (taken == 0 && g_dropped == 0) {
        return dragNotAcceptedErr;
    }
    return noErr;
}

Boolean now_drop_install(WindowRef window)
{
    if (window == NULL || g_installed) {
        return g_installed;
    }
    if (!now_drop_available()) {
        now_log(kLogInfo, "app",
                "drop: Drag Manager absent; window drops unavailable");
        return false;
    }
    /* Real UPPs. On this CFM runtime a UPP is a routine descriptor and a
       cast is a Type 3 the first time the Toolbox calls it - the Drag
       Manager is not the Apple Event Manager and will not tolerate one
       (docs/guest-ui-start-here.md; finding
       carbon-upp-is-not-a-cast-on-cfm). */
    if (g_track_upp == NULL) {
        g_track_upp = NewDragTrackingHandlerUPP(track_drag);
    }
    if (g_receive_upp == NULL) {
        g_receive_upp = NewDragReceiveHandlerUPP(receive_drop);
    }
    if (g_track_upp == NULL || g_receive_upp == NULL) {
        now_log(kLogWarn, "app", "drop: could not make a drag handler UPP");
        return false;
    }
    if (InstallTrackingHandler(g_track_upp, window, NULL) != noErr) {
        now_log(kLogWarn, "app", "drop: InstallTrackingHandler refused");
        return false;
    }
    if (InstallReceiveHandler(g_receive_upp, window, NULL) != noErr) {
        RemoveTrackingHandler(g_track_upp, window);
        now_log(kLogWarn, "app", "drop: InstallReceiveHandler refused");
        return false;
    }
    g_window = window;
    g_installed = true;
    return true;
}

void now_drop_remove(void)
{
    if (!g_installed || g_window == NULL) {
        return;
    }
    if (g_track_upp != NULL) {
        RemoveTrackingHandler(g_track_upp, g_window);
    }
    if (g_receive_upp != NULL) {
        RemoveReceiveHandler(g_receive_upp, g_window);
    }
    g_installed = false;
    g_hilited = false;
    g_window = NULL;
}

void now_drop_shutdown(void)
{
    now_drop_remove();
    if (g_track_upp != NULL) {
        DisposeDragTrackingHandlerUPP(g_track_upp);
        g_track_upp = NULL;
    }
    if (g_receive_upp != NULL) {
        DisposeDragReceiveHandlerUPP(g_receive_upp);
        g_receive_upp = NULL;
    }
}

/* ------------------------------------------------------ Finder icon drop */

/* The classic required-parameter check. An Apple Event carrying a
   keyword this handler never read is one it did not fully understand,
   and answering noErr to that is how a document silently goes nowhere. */
static OSErr missed_any_required(const AppleEvent *event)
{
    DescType actual = typeNull;
    Size size = 0;
    OSErr err;

    err = AEGetAttributePtr(event, keyMissedKeywordAttr, typeWildCard,
                            &actual, NULL, 0, &size);
    if (err == errAEDescNotFound) {
        return noErr;
    }
    return err == noErr ? (OSErr)errAEParamMissed : err;
}

OSErr now_drop_open_documents(const AppleEvent *event, AppleEvent *reply)
{
    AEDescList documents = { typeNull, NULL };
    long count = 0;
    long i;
    short taken = 0;
    OSErr err;

    (void)reply;
    if (event == NULL) {
        return paramErr;
    }
    err = AEGetParamDesc(event, keyDirectObject, typeAEList, &documents);
    if (err != noErr) {
        return err;
    }
    err = missed_any_required(event);
    if (err == noErr) {
        err = AECountItems(&documents, &count);
    }
    for (i = 1; err == noErr && i <= count; ++i) {
        FSSpec spec;
        AEKeyword keyword = 0;
        DescType actual = typeNull;
        Size size = 0;

        if (AEGetNthPtr(&documents, i, typeFSS, &keyword, &actual, &spec,
                        (Size)sizeof spec, &size) != noErr) {
            continue;
        }
        if (size != (Size)sizeof spec) {
            continue;
        }
        if (enqueue(&spec)) {
            ++taken;
        }
    }
    AEDisposeDesc(&documents);
    if (err == noErr && taken == 0 && g_dropped == 0) {
        /* Nothing in the event was a file this application could name.
           Say so in the log rather than in the reply: the Finder shows an
           Apple Event error as a modal of its own, and this is a routine
           "nothing to do", not a failure. */
        now_log(kLogInfo, "app", "odoc: no file specifications in the event");
    }
    return err;
}
