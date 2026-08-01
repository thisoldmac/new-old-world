/*
 * now_ext_act.c - the NOW Extension's act plane (P4).
 *
 * A SEPARATE TRANSLATION UNIT, and the charter's rule is why: planes talk
 * only through the core, never to each other, so review enforces what
 * tbt's separate INIT binaries used to (docs/resident-components.md).
 * Nothing here is called except from now_ext_gne_apply and from the six
 * trap trampolines in now_ext_act_patch.S.
 *
 * WHAT IT IS FOR. Every plane above this one reads. This one is why a
 * semantic scene beats a screenshot: the structure earns its cost when
 * the host can address an ELEMENT instead of a coordinate, and a
 * read-only mirror is strictly worse than sending pixels.
 *
 * HOW IT WORKS, in one paragraph. The core's jGNE filter already runs
 * inside every process that pumps events. When the application arms this
 * plane, the filter additionally looks at one request cell; the next time
 * it finds itself running as the process the request names, it serves it
 * IN THAT CONTEXT. Text is served outright - a TERec and a dialog's item
 * list are per-process memory, unreachable from outside and ordinary
 * from in here. Menu, control and window ops instead ARM a guarded trap
 * patch, so the application's OWN MenuSelect / TrackControl / FindWindow
 * returns the answer the request names and the application then runs its
 * own handler. Nothing simulates a user and no mouse MOTION is injected
 * anywhere, which is what keeps this plane off the emulator.
 *
 * DECISIONS ARE NOT HERE. Every guard, every refusal and every identity
 * check lives in now_act_guard.c, where the host cc can reach it and a
 * mutation dies in a second. This file performs Toolbox effects and
 * decides nothing - the same split as peek_read.c against peek_oracle.c,
 * and it matters more here than anywhere else in the product because
 * this code executes inside applications that did not ask for it.
 *
 * SAFETY POSTURE, stated plainly. A fault in this file takes down
 * whatever application was pumping, or the machine; there is no memory
 * protection on this range. The hot path allocates nothing, calls
 * nothing that moves memory before it has decided to act, and returns
 * after one load and one branch unless the application has deliberately
 * armed the plane. ATTEND THE FIRST METAL BOOT. The core already carried
 * that warning; this plane makes it larger, because for the first time
 * the extension can WRITE into another process rather than only read low
 * memory in its context.
 *
 * Ported from the sibling Mirror project's Portal INIT
 * (/Users/michelle/Lab/Code/timbottu/mirror, parked and complete), whose
 * mechanism is metal-proven THERE. That does not transfer: the same
 * mechanism in different surrounding code is strong evidence, not a
 * measurement, and nothing in this file has been run on any machine.
 *
 * Provenance: P-DOC. Trap numbers are the ONEWORDINLINE on each
 * declaration in Universal Interfaces 3.4; part codes are MacWindows.h;
 * the record fields are Dialogs.h and TextEdit.h. Nothing is derived
 * from a disassembly.
 */

#include <Controls.h>
#include <Events.h>
#include <Dialogs.h>
#include <LowMem.h>
#include <MacMemory.h>
#include <MacWindows.h>
#include <Menus.h>
#include <Quickdraw.h>
#include <TextEdit.h>
#include <Traps.h>

#include <stddef.h>

#include "now_act_guard.h"
#include "peek_table.h"

/* Resident state. The relocated blob sits at a fixed system-heap address
   (sysHeap+locked+detached), so these absolute pointers are valid from
   any later context - the same reason the core never calls
   Retro68FreeGlobals(). */
static NowPeekTable *gNowActTable = NULL;

/* The incumbent traps, for each trampoline to chain to. Referenced from
   assembly, so they are plain module globals with external linkage. */
void *gNowActOldMenuSelect = NULL;
void *gNowActOldTrackControl = NULL;
void *gNowActOldFindWindow = NULL;
void *gNowActOldGrowWindow = NULL;
void *gNowActOldTrackBox = NULL;
void *gNowActOldTrackGoAway = NULL;

/* The trampolines (now_ext_act_patch.S). */
extern void now_act_menuselect_patch(void);
extern void now_act_trackcontrol_patch(void);
extern void now_act_findwindow_patch(void);
extern void now_act_growwindow_patch(void);
extern void now_act_trackbox_patch(void);
extern void now_act_trackgoaway_patch(void);

/* Documented trap numbers, from the ONEWORDINLINE on each declaration
   (Universal Interfaces 3.4) - not from memory and not from a
   disassembly. TrackBox is in the 0xA8xx range and the rest in 0xA9xx;
   both are ToolTrap, which is what NGetTrapAddress is told below. */
#define kNowActMenuSelectTrap  0xA93D
#define kNowActTrackControlTrap 0xA968
#define kNowActFindWindowTrap  0xA92C
#define kNowActGrowWindowTrap  0xA92B
#define kNowActTrackBoxTrap    0xA83B
#define kNowActTrackGoAwayTrap 0xA91E

/* The Control Manager's action procedure: what actually scrolls a scroll
   bar while it is being tracked. */
typedef pascal void (*NowActActionProc)(ControlHandle control, short part);

/* ---- installation, deferred until the plane is armed -------------------
 *
 * The charter's plane model: code beyond the boot-minimal core executes
 * only after the application writes an arm request, with the filter -
 * already in a process's context - performing any in-context
 * installation. So the six trap patches go in on the first armed pass,
 * not at boot. A machine that never opens the mirror never has a patched
 * MenuSelect.
 *
 * They are never removed. Unpatching is the one thing more dangerous
 * than patching: a patch that vanishes while a caller is inside it is a
 * jump into freed code. Disarming instead makes every trampoline's guard
 * decline, so the traps behave exactly as they would without us - see
 * now_act_armed_cell().
 *
 * Each is installed only if its incumbent could be read, and the serve
 * path refuses a sub-op whose patch is missing rather than arming
 * something that can never fire. */
static void install_patch(unsigned short trap, void *shim, void **saved,
                          NowPeekU32 *patches, unsigned long bit)
{
    void *old = (void *)NGetTrapAddress(trap, ToolTrap);

    if (old == NULL) {
        return;
    }
    *saved = old;
    NSetTrapAddress((UniversalProcPtr)shim, trap, ToolTrap);
    *patches |= (NowPeekU32)bit;
}

static void act_install(NowPeekActCell *cell)
{
    static int installed = 0;

    if (installed) {
        return;
    }
    installed = 1;
    cell->patches = 0;
    install_patch(kNowActMenuSelectTrap, (void *)now_act_menuselect_patch,
                  &gNowActOldMenuSelect, &cell->patches,
                  kNowPeekActPatchMenu);
    install_patch(kNowActTrackControlTrap, (void *)now_act_trackcontrol_patch,
                  &gNowActOldTrackControl, &cell->patches,
                  kNowPeekActPatchControl);
    install_patch(kNowActFindWindowTrap, (void *)now_act_findwindow_patch,
                  &gNowActOldFindWindow, &cell->patches,
                  kNowPeekActPatchFindWindow);
    install_patch(kNowActGrowWindowTrap, (void *)now_act_growwindow_patch,
                  &gNowActOldGrowWindow, &cell->patches,
                  kNowPeekActPatchGrowWindow);
    install_patch(kNowActTrackBoxTrap, (void *)now_act_trackbox_patch,
                  &gNowActOldTrackBox, &cell->patches,
                  kNowPeekActPatchTrackBox);
    install_patch(kNowActTrackGoAwayTrap, (void *)now_act_trackgoaway_patch,
                  &gNowActOldTrackGoAway, &cell->patches,
                  kNowPeekActPatchTrackGoAway);
}

/* ---- the text ops ------------------------------------------------------
 *
 * No patch and no armed window: the hook does the work directly, so
 * there is no interval during which a user's own call could be answered.
 * What replaces the patch's identity check is a stricter one, because
 * the hazard here is the wrong OBJECT rather than the wrong moment - see
 * now_act_window_is_ours(). Nothing is written on the strength of a
 * request being pending. */

static unsigned long act_next_window(unsigned long window, void *ctx)
{
    (void)ctx;
    return (unsigned long)((WindowPeek)window)->nextWindow;
}

/* How much of a TERec is actually touched. NOT sizeof(TERec): the header
   declares lineStarts[16001], so sizeof is ~32 KB while a real record is
   allocated to fit its line count. Everything read below - viewRect,
   teLength, hText, inPort - lives before lineStarts. */
#define kNowActTeRecNeed ((unsigned long)offsetof(TERec, lineStarts))

/* The application heap zone's bounds, for the plausibility check that
   has to happen BEFORE an arbitrary caller-supplied handle is
   dereferenced. ApplZone is the documented per-process heap zone;
   bkLim is its high limit. */
static void act_zone_bounds(unsigned long *lo, unsigned long *hi)
{
    THz zone = LMGetApplZone();

    if (zone == NULL) {
        *lo = 0;
        *hi = 0;
        return;
    }
    *lo = (unsigned long)zone;
    *hi = (unsigned long)zone->bkLim;
}

/* Copy a TERec's text into the reply. teLength is the record's own count
   and hText its text handle; we take the shorter of that and the buffer
   and report the TRUE length separately, so a long document reads as
   truncated rather than as a short document. */
static void act_te_read(NowPeekActCell *cell, TEHandle te)
{
    unsigned long lo, hi;
    Handle        h = (**te).hText;
    long          len = (long)(**te).teLength;
    long          take;
    SignedByte    saved;

    cell->text_te = (NowPeekU32)(unsigned long)te;
    cell->text_length = (NowPeekI32)len;
    cell->text_buf_length = 0;
    if (h == NULL || len <= 0) {
        return;
    }
    /* hText comes out of a record we have only BOUNDED, not proved, so it
       gets the same treatment before it is locked and copied from. */
    act_zone_bounds(&lo, &hi);
    if (!now_act_handle_in_zone(lo, hi, (unsigned long)h, (unsigned long)len)) {
        return;
    }
    if (*h == NULL
        || !now_act_master_in_zone(lo, hi, (unsigned long)*h,
                                   (unsigned long)len)) {
        return;
    }
    take = now_act_text_take(len, (long)kNowPeekActTextMax);
    saved = HGetState(h);
    HLock(h);
    BlockMoveData(*h, cell->text_buf, take);
    HSetState(h, saved);
    cell->text_buf_length = (NowPeekI32)take;
}

/* Resolve the request to a TEHandle, with the identity check its kind
   demands. Returns NULL having named the error - never a best guess. */
static TEHandle act_resolve_te(NowPeekActCell *cell, WindowPtr w,
                               unsigned long *error)
{
    unsigned long lo, hi;
    TEHandle      te;

    if (cell->text_kind == kNowPeekActTextDialogTe) {
        if (((WindowPeek)w)->windowKind != dialogKind) {
            *error = kNowPeekActErrNotDialog;
            return NULL;
        }
        te = ((DialogPeek)w)->textH;
        if (te == NULL || *te == NULL) {
            *error = kNowPeekActErrBadTe;
            return NULL;
        }
        return te;
    }

    /* The caller named the handle, so the handle has to prove it belongs
       to the window the caller also named. A TEHandle from another
       process fails, because its inPort is not one of our windows.

       BOUND BEFORE DEREFERENCING, and the order is the whole point: a
       handle of 1234 measured upstream did not come back refused, it
       hung and took the target application with it, because the inPort
       test is two levels of dereference of an arbitrary integer and it
       ran before anything established the integer addressed memory. */
    te = (TEHandle)(unsigned long)cell->text_handle;
    act_zone_bounds(&lo, &hi);
    if (!now_act_handle_in_zone(lo, hi, (unsigned long)te,
                                kNowActTeRecNeed)) {
        *error = kNowPeekActErrBadTe;
        return NULL;
    }
    if (*te == NULL
        || !now_act_master_in_zone(lo, hi, (unsigned long)*te,
                                   kNowActTeRecNeed)) {
        *error = kNowPeekActErrBadTe;
        return NULL;
    }
    if ((void *)(**te).inPort != (void *)w) {
        *error = kNowPeekActErrBadTe;
        return NULL;
    }
    return te;
}

/* TESetText does NOT display the new text (Inside Macintosh: Text,
   TextEdit), so a set that stops there leaves the screen showing the old
   document - the single most misleading failure this op can have.
   Recalculate, redraw, and ALSO invalidate so the application's own
   update path runs on its next pass and agrees with us.

   The port is saved and restored: this runs inside the application's own
   GetNextEvent, and leaving a different port current would be a defect
   with no obvious cause. */
static void act_te_redraw(TEHandle te, WindowPtr w)
{
    GrafPtr save;
    Rect    view = (**te).viewRect;

    GetPort(&save);
    SetPort((GrafPtr)w);
    TECalText(te);
    EraseRect(&view);
    TEUpdate(&view, te);
    InvalRect(&view);
    SetPort(save);
}

static unsigned long act_serve_ditem(NowPeekActCell *cell, WindowPtr w,
                                     int is_set)
{
    DialogPtr d = (DialogPtr)w;
    Handle    item_h = NULL;
    Rect      box;
    short     type = 0;
    Str255    str;
    short     item = (short)cell->text_item;
    long      take;

    if (((WindowPeek)w)->windowKind != dialogKind) {
        return kNowPeekActErrNotDialog;
    }
    if (item < 1 || item > CountDITL(d)) {
        return kNowPeekActErrNoItem;
    }
    GetDialogItem(d, item, &type, &item_h, &box);
    cell->text_item_type = (NowPeekI32)type;
    if (!now_act_item_type_is_text((long)type)) {
        return kNowPeekActErrNotText;
    }
    if (item_h == NULL) {
        return kNowPeekActErrNoItem;
    }

    if (is_set) {
        /* A Str255 is the Dialog Manager's own boundary here, so 255 is
           the ceiling regardless of what the cell can carry. */
        take = now_act_text_take((long)cell->text_length, 255L);
        str[0] = (unsigned char)take;
        if (take > 0) {
            BlockMoveData(cell->text_buf, &str[1], take);
        }
        /* SetDialogItemText both stores AND draws the item, so the
           dialog case needs no invalidation of its own. */
        SetDialogItemText(item_h, str);
        /* If this item is the one the Dialog Manager currently has open
           for editing, its live TERec holds a copy SetDialogItemText did
           not touch, and the next keystroke would resurrect the old
           string. editField is the item number MINUS ONE (Dialogs.h).
           Re-selecting makes the Dialog Manager reload from the item. */
        if (((DialogPeek)d)->editField == (short)(item - 1)) {
            SelectDialogItemText(d, item, 0, 32767);
        }
    }

    /* Read back from the OBJECT on both paths: for get this is the
       answer, and for set it is the only evidence worth having. A verb's
       own say-so is what upstream's four retracted findings were made
       of. */
    GetDialogItemText(item_h, str);
    cell->text_length = (NowPeekI32)str[0];
    take = now_act_text_take((long)str[0], (long)kNowPeekActTextMax);
    cell->text_buf_length = (NowPeekI32)take;
    if (take > 0) {
        BlockMoveData(&str[1], cell->text_buf, take);
    }
    cell->text_te = (NowPeekU32)(unsigned long)((DialogPeek)d)->textH;
    return kNowPeekActErrNone;
}

static unsigned long act_serve_text(NowPeekActCell *cell, int is_set)
{
    WindowPtr     w = (WindowPtr)(unsigned long)cell->text_window;
    unsigned long error = kNowPeekActErrNone;
    TEHandle      te;
    long          take;

    /* THE IDENTITY CHECK, before anything is read and long before
       anything is written: the named window must be in the window list
       of the process we are running as right now. */
    if (w == NULL
        || !now_act_window_is_ours((unsigned long)LMGetWindowList(),
                                   (unsigned long)w, act_next_window, NULL)) {
        return kNowPeekActErrNotOurWindow;
    }

    if (cell->text_kind == kNowPeekActTextDitem) {
        return act_serve_ditem(cell, w, is_set);
    }
    if (cell->text_kind != kNowPeekActTextTe
        && cell->text_kind != kNowPeekActTextDialogTe) {
        return kNowPeekActErrTextKind;
    }

    te = act_resolve_te(cell, w, &error);
    if (te == NULL) {
        return error;
    }
    if (is_set) {
        take = now_act_text_take((long)cell->text_length,
                                 (long)kNowPeekActTextMax);
        /* TESetText(text, length, hTE) replaces the record's text and
           resets the selection; it does not draw. */
        TESetText((Ptr)cell->text_buf, take, te);
        act_te_redraw(te, w);
    }
    act_te_read(cell, te);
    return kNowPeekActErrNone;
}

/* ---- key (V2): a modified keystroke, served outright ------------------
 *
 * PPostEvent is CALL_NOT_IN_CARBON, so NOW's Carbon application can queue
 * a keystroke (PostEvent) but cannot get back the queue ELEMENT a
 * modifier has to be stamped on. This context can: it is 68K resident,
 * not Carbon, and act_post_click() above already proves the mechanism for
 * a mouse press. This is the same mechanism for a key.
 *
 * Ported from the sibling Mirror project's verb_key (fix commit f4b4742,
 * parked and metal-proven THERE - the mechanism, not the measurement; see
 * this file's own header for why that distinction is stated every time).
 * Upstream's fix was exactly this shape: post keyDown, stamp
 * evtQModifiers on the element PPostEvent hands back, wait a SHORT bound
 * number of ticks, then post keyUp. The wait is not decorative - posting
 * the pair with no gap between them lost the modifier on the port it was
 * measured on: a keyUp queued in the same instant as its keyDown can be
 * dequeued as part of the same pass that reads the stamp this function
 * just wrote, ahead of whatever in the target's own event handling was
 * going to notice it was there. Bounded and polled via LMGetTicks rather
 * than any form of yield, because this runs INSIDE the target's own
 * WaitNextEvent call - there is no recursive call to make that would let
 * it give up the processor instead of spinning. */
#define kNowActKeyWaitTicks 3UL

static int act_post_key(NowPeekActCell *cell)
{
    EvQElPtr      down = NULL;
    EvQElPtr      up = NULL;
    unsigned long start;
    UInt32        message;

    message = ((UInt32)((unsigned long)cell->key_code & 0xFFUL) << 8)
              | (UInt32)((unsigned long)cell->key_char & 0xFFUL);

    if (PPostEvent(keyDown, message, &down) != noErr || down == NULL) {
        cell->fired = 0;
        return 0;
    }
    down->evtQModifiers = (short)cell->key_mods;

    start = (unsigned long)LMGetTicks();
    while ((unsigned long)LMGetTicks() - start < kNowActKeyWaitTicks) {
        /* Bounded spin - see the header above for why this cannot yield
           instead. */
    }

    if (PPostEvent(keyUp, message, &up) == noErr && up != NULL) {
        up->evtQModifiers = (short)cell->key_mods;
    }
    /* keyUp's own refusal is not THIS op's failure: it is not enabled in
       the system event mask on classic Mac OS and declines on every
       trial, including the ones that actuate correctly (the guest's
       unmodified `key` verb already reports this as a row rather than an
       error - input_cmds.c). The down half, stamped with the modifier
       this application cannot stamp itself, is the whole mechanism. */
    cell->fired = 1;
    return 1;
}

static unsigned long act_serve_key(NowPeekActCell *cell)
{
    return act_post_key(cell) ? kNowPeekActErrNone : kNowPeekActErrPostFailed;
}

/* ---- menugeom (V2): one menu's per-item rects, served outright --------
 *
 * GetMenuHandle and a menu's MDEF Handle are only meaningful in the
 * process that installed the menu - the same reason the text ops read a
 * TERec only in the window's owning context rather than trying to reach
 * it from outside. So this, like text, is served in the hook rather than
 * behind an armed patch: there is no trap to answer, only a Handle to
 * read.
 *
 * P-DOC (Inside Macintosh: Macintosh Toolbox Essentials, the Menu
 * Manager, and the MDEF message set in Menus.h - mCalcItemMsg is the
 * message that asks an MDEF to compute one item's rect without drawing
 * it). Ported from the sibling Mirror project's Portal INIT
 * (pt_serve_menu_geometry, portal.c) as a MECHANISM; nothing about this
 * function has run on any machine, in either project. */
static unsigned long act_serve_menugeom(NowPeekActCell *cell)
{
    MenuHandle mh;
    Handle     proc_h;
    pascal void (*proc)(short, MenuHandle, Rect *, Point, short *);
    SignedByte saved;
    short      count;
    short      i;
    Rect       bounds;
    Point      pt;

    mh = GetMenuHandle((short)cell->menu_id);
    if (mh == NULL) {
        return kNowPeekActErrNoMenu;
    }
    proc_h = (*mh)->menuProc;
    if (proc_h == NULL) {
        return kNowPeekActErrNoMenu;
    }

    count = CountMItems(mh);
    if (count < 0) {
        count = 0;
    }
    if (count > (short)kNowPeekActMenuItemMax) {
        count = (short)kNowPeekActMenuItemMax;
    }

    /* The MDEF's Handle may be purgeable between menus, the same
       consideration act_te_read already gives a caller-named TEHandle -
       locked only for the loop, restored to its incoming state on the
       way out. */
    saved = HGetState(proc_h);
    HLock(proc_h);
    proc = (pascal void (*)(short, MenuHandle, Rect *, Point, short *))
               (unsigned long)*proc_h;

    /* Seeded from the menu's own published width/height: mCalcItemMsg
       computes an ITEM's rect inside the bounds it is handed and does not
       itself establish where the menu sits, which this context has no
       better source for than the menu's own record. hitPt is unused by
       this message; zeroed rather than left to read as meaningful. */
    bounds.top = 0;
    bounds.left = 0;
    bounds.right = (*mh)->menuWidth;
    bounds.bottom = (*mh)->menuHeight;
    pt.h = 0;
    pt.v = 0;

    cell->menu_width = (NowPeekI32)(*mh)->menuWidth;
    cell->menu_height = (NowPeekI32)(*mh)->menuHeight;
    cell->menu_item_count = (NowPeekI32)count;

    for (i = 1; i <= count; i++) {
        Rect  r = bounds;
        short which = i;

        proc(mCalcItemMsg, mh, &r, pt, &which);
        cell->menu_item_rects[i - 1].top = (NowPeekU16)(unsigned short)r.top;
        cell->menu_item_rects[i - 1].left = (NowPeekU16)(unsigned short)r.left;
        cell->menu_item_rects[i - 1].bottom
            = (NowPeekU16)(unsigned short)r.bottom;
        cell->menu_item_rects[i - 1].right
            = (NowPeekU16)(unsigned short)r.right;
    }

    HSetState(proc_h, saved);
    return kNowPeekActErrNone;
}

/* ---- the ABI selftest --------------------------------------------------
 *
 * Call MenuSelect ourselves, armed, and check we get back exactly what
 * the patch answered with. This runs the REAL calling convention - the
 * caller pushes a result slot, we answer, the callee pops - so a wrong
 * result offset or a missing pop shows up as a mismatch rather than as
 * an application that mysteriously does nothing.
 *
 * It exists because that failure is SILENT. A patch with the result in
 * the wrong slot reports firing and the application does nothing,
 * because the value it read was never the value we wrote. A wrong ABI
 * does not crash, it lies, so the mechanism has to be able to check
 * itself.
 *
 * Point (0,0) is outside the menu bar, so if the patch somehow does not
 * answer, the real MenuSelect returns 0 immediately without drawing or
 * tracking anything. Either way this is cheap and side-effect free. */
static unsigned long act_serve_selftest(NowPeekActCell *cell)
{
    Point p0;
    long  got;

    cell->menu_id = 999;                /* a menu that does not exist */
    cell->item_index = 7;
    cell->selftest_want = (NowPeekU32)(((999UL & 0xFFFFUL) << 16) | 7UL);
    cell->selftest_got = 0;
    cell->fired = 0;
    /* Negative arm point: unguarded on the press, which ONLY this op may
       be - it answers a MenuSelect it made itself and rides no user
       click at all. */
    cell->arm_point_h = -1;
    cell->arm_point_v = -1;
    cell->armed = kNowPeekActArmReady;

    p0.h = 0;
    p0.v = 0;
    got = MenuSelect(p0);
    cell->selftest_got = (NowPeekU32)got;
    cell->armed = kNowPeekActArmNone;

    if (!cell->fired) {
        return kNowPeekActErrNoPatch;
    }
    if ((NowPeekU32)got != cell->selftest_want) {
        return kNowPeekActErrAbi;       /* answered, caller read junk */
    }
    return kNowPeekActErrNone;
}

/* ---- posting the click ------------------------------------------------
 *
 * THE FALLBACK PATH, and it is kept rather than repaired.
 *
 * This function posts the press from inside whichever jGNE pass V3's
 * click_not_a5 rule allows, which is what the plane did exclusively
 * until the pump landed. The reasoning was that NOW's application is
 * CARBON - PPostEvent and the low-memory mouse globals are
 * CALL_NOT_IN_CARBON, so it cannot queue an event whose `where` it
 * controls - while the resident filter is 68K and can. The reasoning was
 * sound and the code is correct; it simply has nowhere to run. Every
 * pass measured belonged to the TARGET's own world (0/5, 293-303 passes
 * in five seconds), because a background Carbon application's
 * WaitNextEvent never falls through to the classic Event Manager and
 * nothing else on an idle Mac was pumping (docs/open-issues.md,
 * act-click-no-pass).
 *
 * So the delivering route is now the pump - a classic faceless
 * application that both pumps and posts from its own context, which is
 * the shape the sibling Mirror project measured 20/20
 * (contract/peek_table.h, P4b). This path stays behind
 * now_act_click_route() so that a machine with no pump installed
 * degrades to EXACTLY the behaviour the ledger already describes, rather
 * than to an unknown one.
 *
 * What remains true of it either way, and is why the pump copies it
 * rather than inventing something:
 *
 *   - `where` is stamped on the queue element rather than left to the
 *     live mouse. The ADB (metal) or emulated mouse VBL can overwrite
 *     MouseLocation between the set and the application's dequeue, and
 *     the click would land wherever the real pointer happens to be -
 *     which for this plane is not a cosmetic bug, because the point IS
 *     the identity check.
 *   - Nothing here injects mouse MOTION. Motion is what needed QMP and
 *     what made a coordinate drag emulator-only; a queued press is an
 *     ordinary Event Manager call.
 *
 * Returns 1 when both events were queued. A refused queue is reported as
 * its own error rather than as "armed and never taken": nothing was
 * asked of the application at all, and those are different repairs. */
/* Where this request's press goes. One implementation, because the
   point is the menu op's IDENTITY CHECK as well as its coordinate: the
   guard compares MenuSelect's argument against arm_point, so a second
   spelling of this choice is a second chance for the press and the guard
   to disagree - which fails as a request that arms and is never taken,
   the hardest failure in this plane to attribute. */
static void act_click_point(const NowPeekActCell *cell, Point *pt)
{
    if (cell->op == (NowPeekU32)kNowPeekActOpMenu) {
        pt->h = (short)cell->arm_point_h;
        pt->v = (short)cell->arm_point_v;
    } else {
        pt->h = (short)cell->click_h;
        pt->v = (short)cell->click_v;
    }
}

static int act_post_click(NowPeekActCell *cell)
{
    Point    pt;
    EvQElPtr down = NULL;
    EvQElPtr up = NULL;

    act_click_point(cell, &pt);

    /* Cosmetic, plus applications that re-read GetMouse. The
       authoritative location is stamped per event below.
       MEASURED AND NOT THE FAULT (2026-08-01): the whole sequence was
       run once with these four low-memory writes removed - byte for byte
       the sequence that DOES deliver a keyDown from this same context on
       this same machine - and the press was still never delivered, 0/6.
       They are back because they are upstream's proven shape and because
       removing them is an unforced divergence on a path that is broken
       for some other reason. */
    LMSetMouseTemp(pt);
    LMSetRawMouseLocation(pt);
    LMSetMouseLocation(pt);

    LMSetMouseButtonState(0x00);              /* button down */
    if (PPostEvent(mouseDown, 0, &down) != noErr || down == NULL) {
        LMSetMouseButtonState(0x80);
        return 0;
    }
    down->evtQWhere = pt;
    down->evtQModifiers = 0;
    LMSetMouseButtonState(0x80);              /* button up */
    if (PPostEvent(mouseUp, 0, &up) != noErr || up == NULL) {
        return 0;
    }
    up->evtQWhere = pt;
    up->evtQModifiers = 0;
    return 1;
}

/* ---- handing the ask to the pump (V4) ----------------------------------
 *
 * The CELL's ask (click_pending, V3) is still the one the application
 * waits on; the pump's ticket is how this filter gets it served. So the
 * two are not parallel routes to the same word - the ticket is published
 * from the cell's ask, and the cell's ask is closed with the pump's
 * answer, through the same now_act_click_done V3 already uses. Whichever
 * route serves a press, the application reads exactly one story.
 *
 * One outstanding ticket at a time, because the cell serves one request
 * at a time by its own design. It is cleared whenever no ask is pending,
 * so an abandoned request cannot leave the next one waiting on a reply
 * that was never for it. */
static unsigned long gActPumpTicket;

static void act_click_via_pump(NowPeekActCell *cell, NowPeekActPump *pump)
{
    Point pt;

    if (gActPumpTicket == 0) {
        act_click_point(cell, &pt);
        /* Publish and return. This runs inside a jGNE pass under
           cooperative scheduling, so the pump cannot get the processor
           until we have returned and our host has yielded: waiting here
           would guarantee the timeout it was waiting to avoid. Modifiers
           0 and one press - the two things the cell has no field for
           today, spelled once here rather than defaulted twice. */
        gActPumpTicket = now_act_click_request(pump, (long)pt.h, (long)pt.v,
                                               0, 1);
        return;
    }
    switch (now_act_click_state(pump, gActPumpTicket)) {
    case kNowActTicketPosted:
        now_act_click_done(cell, 1);
        gActPumpTicket = 0;
        break;
    case kNowActTicketRefused:
        now_act_click_done(cell, 0);
        gActPumpTicket = 0;
        break;
    default:
        break;                          /* still with the pump */
    }
}

/* ---- the filter's act pass --------------------------------------------
 *
 * Called from now_ext_gne_apply on every GetNextEvent/WaitNextEvent in
 * whatever process is pumping, and only while the plane is armed. The
 * common case is one load, one compare and a return: no request pending,
 * or one that names a different A5 world. */
void now_ext_act_apply(NowPeekTable *table);

void now_ext_act_apply(NowPeekTable *table)
{
    NowPeekActCell *cell = now_act_armed_cell(table);
    unsigned long   a5;
    unsigned long   error = kNowPeekActErrNone;
    int             verdict;

    if (cell == NULL) {
        return;
    }
    gNowActTable = table;

    a5 = (unsigned long)LMGetCurrentA5();
    /* The click, BEFORE anything else this pass does. It is not a request
       being served - it is one word the application asked a pass in ITS
       OWN process to act on, so it is answered wherever it is due and
       does not touch the request's status, arm or seqlock. See the
       click_a5 block in contract/peek_table.h for why the click no longer
       goes out from the target's own pass. */
    if (cell->click_pending == 0) {
        /* No ask outstanding, so no ticket is either: the next ask gets a
           fresh publish rather than inheriting an abandoned one's reply. */
        gActPumpTicket = 0;
    } else {
        NowPeekActPump *pump = now_act_pump(table);

        /* Count EVERY pass that sees the ask, not only the ones that may
           serve it: a run where this stays zero says the hook is not
           reached at all while the wire waits, which is a different
           repair from a post that was refused. */
        cell->click_passes++;
        cell->click_last_a5 = (NowPeekU32)a5;
        if (now_act_click_route(pump, (unsigned long)LMGetTicks())
            == kNowActClickPump) {
            act_click_via_pump(cell, pump);
            return;
        }
        /* No live pump: V3's route stands exactly as it did, including
           its measured outcome. Drop any ticket we were holding - the
           pump that owed us an answer is gone. */
        gActPumpTicket = 0;
        if (now_act_click_due(cell, a5)) {
            now_act_click_done(cell, act_post_click(cell));
            return;
        }
    }

    /* In-context installation, on the first armed pass - the plane model
       (docs/resident-components.md). Before this, a machine that never
       armed the plane has an unpatched trap table. */
    act_install(cell);

    verdict = now_act_serve_begin(cell, a5, (unsigned long)LMGetTicks());
    switch (verdict) {
    case kNowActServeSkip:
        return;
    case kNowActServeMove:
        /* DragWindow is pascal void: it performs the move itself and
           hands the application nothing back, so there is no question to
           answer and no application code that runs after it. Calling
           MoveWindow here IS what DragWindow would have done, minus the
           tracking loop and the mouse motion that loop needs - and that
           motion is the only thing in the act plane that was ever
           emulator-only.

           Made at jGNE time, inside the application's own GetNextEvent -
           the moment it would itself have been handling the click. It
           repaints and queues an update event; it does not re-enter the
           Event Manager. `front` is false so the move does not also
           raise the window: one request, one effect. */
        MoveWindow((WindowPtr)(unsigned long)cell->window_ptr,
                   (short)cell->win_h, (short)cell->win_v, false);
        cell->fired = 1;
        cell->armed = kNowPeekActArmNone;
        cell->find_window_fired = 0;    /* no patch was involved */
        break;
    case kNowActServeText:
        error = act_serve_text(cell, cell->op == kNowPeekActOpTextSet);
        break;
    case kNowActServeSelfTest:
        error = act_serve_selftest(cell);
        break;
    case kNowActServeKey:
        error = act_serve_key(cell);
        break;
    case kNowActServeMenuGeom:
        error = act_serve_menugeom(cell);
        break;
    case kNowActServeArmed:
        /* Armed in the target's own context, which proves the target is
           alive and pumping before any patch goes live. The click that
           makes the application call the patched trap is NOT queued here
           any more: it goes out from the application's own pass, once
           this arm has been published. */
        break;
    case kNowActServeRefused:
    default:
        error = cell->error;
        if (error == kNowPeekActErrNone) {
            error = kNowPeekActErrBadOp;
        }
        break;
    }
    now_act_serve_commit(cell, error);
}

/* ---- the six patch answers --------------------------------------------
 *
 * Called from the trampolines with the trap's own arguments. Each of
 * them delegates its decision to now_act_guard.c and does nothing else,
 * except the control patch, which has one Toolbox effect to perform. */

long now_act_patch_menuselect(long start_pt);
short now_act_patch_trackcontrol(void *control, void *action_proc);
short now_act_patch_findwindow(unsigned long point, void **out_window);
long now_act_patch_growwindow(void *window, unsigned long point);
short now_act_patch_trackbox(void *window, long part);
short now_act_patch_trackgoaway(void *window, unsigned long point);

long now_act_patch_menuselect(long start_pt)
{
    unsigned long   a5 = (unsigned long)LMGetCurrentA5();
    NowPeekActCell *cell;

    /* Before now_act_armed_cell, so an entry counts even with the plane
       disarmed: "the patch is installed and the system calls it" is a
       fact the four window traps could establish and these two could
       not. Until this line, 0/10 menuact could not distinguish a
       MenuSelect that never happened from one that was declined. */
    now_act_verb_trap_hit(gNowActTable, kNowActVerbMenu, a5);
    cell = now_act_armed_cell(gNowActTable);

    return now_act_menu_answer(cell, a5, start_pt,
                               (unsigned long)LMGetTicks());
}

short now_act_patch_trackcontrol(void *control, void *action_proc)
{
    unsigned long    a5 = (unsigned long)LMGetCurrentA5();
    NowPeekActCell  *cell;
    unsigned long    call = 0;
    short            part;

    now_act_verb_trap_hit(gNowActTable, kNowActVerbControl, a5);
    cell = now_act_armed_cell(gNowActTable);

    part = now_act_control_answer(cell, a5,
                                  (unsigned long)control,
                                  (unsigned long)action_proc,
                                  (unsigned long)LMGetTicks(), &call);
    if (part == 0) {
        return 0;
    }
    /* TrackControl has TWO halves and only one is the return value. A
       push button does its work AFTER TrackControl returns, from the
       part code, so answering is enough. A scroll bar does its work
       DURING tracking, in the action procedure the Control Manager calls
       repeatedly while the button is held - so answering the return
       value alone drives buttons and does nothing at all to a scroll
       bar. Call the action ONCE, which is what a single click of
       tracking does; a loop here would be a held button nobody asked
       for, and a caller that wants to page twice asks twice.
       The sentinel and the thumb are filtered in the guard. */
    if (call != 0) {
        NowActActionProc action = (NowActActionProc)call;

        action((ControlHandle)control, part);
    }
    return part;
}

short now_act_patch_findwindow(unsigned long point, void **out_window)
{
    NowPeekActCell *cell = now_act_armed_cell(gNowActTable);
    unsigned long   a5 = (unsigned long)LMGetCurrentA5();
    unsigned long   window = 0;
    short           part;

    now_act_trap_hit(cell, 0, a5);      /* entered, before any guard */
    if (out_window == NULL) {
        return 0;
    }
    part = now_act_findwindow_answer(cell, a5, point,
                                          (unsigned long)LMGetTicks(),
                                          &window);
    if (part == 0) {
        return 0;
    }
    *out_window = (void *)window;
    return part;
}

long now_act_patch_growwindow(void *window, unsigned long point)
{
    NowPeekActCell *cell = now_act_armed_cell(gNowActTable);
    unsigned long   a5 = (unsigned long)LMGetCurrentA5();

    (void)point;                        /* the request already names the
                                           size; GrowWindow's start point
                                           is the application's, not ours */
    now_act_trap_hit(cell, 1, a5);
    return now_act_grow_answer(cell, a5, (unsigned long)window,
                               (unsigned long)LMGetTicks());
}

short now_act_patch_trackbox(void *window, long part)
{
    NowPeekActCell *cell = now_act_armed_cell(gNowActTable);
    unsigned long   a5 = (unsigned long)LMGetCurrentA5();

    now_act_trap_hit(cell, 2, a5);
    return (short)now_act_trackbox_answer(cell, a5,
                                               (unsigned long)window, part,
                                               (unsigned long)LMGetTicks());
}

short now_act_patch_trackgoaway(void *window, unsigned long point)
{
    NowPeekActCell *cell = now_act_armed_cell(gNowActTable);
    unsigned long   a5 = (unsigned long)LMGetCurrentA5();

    (void)point;
    now_act_trap_hit(cell, 3, a5);
    return (short)now_act_goaway_answer(cell, a5, (unsigned long)window,
                                        (unsigned long)LMGetTicks());
}
