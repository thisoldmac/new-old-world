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

/* The one drag item. The Drag Manager wants a reference number per item
   and this drag has exactly one, always: an offer holds one file (a
   folder is refused before we get here). */
enum { kOfferItemRef = 1 };

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
        now_log(kLogWarn, "mirror", "drag promise #%ld did not land", id);
    }
    return landed;
}

static pascal OSErr drag_send_data(FlavorType type, void *refcon,
                                   DragItemRef item, DragRef drag)
{
    FSSpec spec;
    short vref;
    long dir;

    (void)refcon;

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

    now_log(kLogInfo, "mirror", "drag promise streaming %.31s into dir %ld",
            g_drag.item.name, dir);
    if (!stream_promise(vref, dir, &spec)) {
        now_continuity_drag_promise_end(&g_drag, 0);
        return cantGetFlavorErr;
    }
    /* The file exists, whole, at the place the person dropped it. The
       Finder positions it from here. */
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
   that failed to start because an icon was missing is a broken one. */
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
    LockPixels(GetGWorldPixMap(world));

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

    UnlockPixels(GetGWorldPixMap(world));
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
    DragSendDataUPP upp = send_upp();

    if (upp == NULL) {
        now_log(kLogError, "mirror", "drag: no send-data UPP; not started");
        now_continuity_drag_start_failed(&g_drag);
        return;
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
       demand, which is what makes this a promise rather than a file. */
    AddDragItemFlavor(drag, kOfferItemRef, kDragPromisedFlavor, NULL, 0,
                      flavorNotSaved);
    /* The name the Finder should use, offered as a hint rather than
       imposed — the receiver remains free to uniquify it. */
    CopyCStringToPascal(g_drag.item.name, pname);
    if (pname[0] > 0) {
        AddDragItemFlavor(drag, kOfferItemRef, kFlavorTypeClippingName,
                          &pname[1], (Size)pname[0], 0);
    }

    GetMouse(&where);
    LocalToGlobal(&where);
    drag_bounds(where, &bounds);
    SetDragItemBounds(drag, kOfferItemRef, &bounds);

    region = NewRgn();
    if (region != NULL) {
        RectRgn(region, &bounds);
    }
    image = build_drag_image(&bounds);
    if (image != NULL && region != NULL) {
        Point offset;

        offset.h = bounds.left;
        offset.v = bounds.top;
        SetDragImage(drag, GetGWorldPixMap(image), region, offset,
                     kDragRegionAndImage);
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

    /* THE WIRE STOPS HERE, and that is documented rather than fixed:
       TrackDrag takes no idle callback, exactly like MenuSelect and
       DragWindow in pump.h's list of what cannot be pumped. The
       difference — and the reason the promise callback pumps by hand —
       is that the drop INSIDE this call is where bytes have to move. */
    {
        OSErr track = TrackDrag(drag, &event, region);
        int verdict = now_continuity_drag_ended(&g_drag, track == noErr);

        now_log(track == noErr && verdict == kNowDragOK
                    ? kLogInfo : kLogWarn,
                "mirror", "drag %.31s ended: %s (TrackDrag %d)",
                g_drag.item.name, now_continuity_drag_code(verdict),
                (int)track);
    }

    /* Torn down in every case, including the failures above: classic
       Finder is unforgiving of a drag that never ends, and a DragRef
       leaked here is a drag that never does. */
    DisposeDrag(drag);
    if (region != NULL) {
        DisposeRgn(region);
    }
    if (image != NULL) {
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
}
