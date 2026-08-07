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

/* P7's vehicle (now_ext_drag.c). Declared rather than headered for the
   same reason the liveness net is: this file is P4 and must not start
   depending on P7's internals. Three entry points is the whole seam -
   press, the cell, and the way to hand a begun gesture back when the
   press event this file owes it cannot be queued. */
extern int now_ext_drag_press(NowPeekTable *table, NowPeekU32 session,
                              NowPeekU32 target_a5, NowPeekI32 h,
                              NowPeekI32 v, NowPeekU32 idle_asked,
                              NowPeekU32 cap_asked);
extern NowPeekDragCell *now_ext_drag_cell(NowPeekTable *table);
extern void now_ext_drag_abandon(NowPeekTable *table);
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

/* P8, the cursor plane. Declared rather than included for the same
   reason the core declares the planes it boots: this file knows one
   entry point and nothing about how the sprite is moved. */
extern int now_ext_cursor_place(NowPeekI32 h, NowPeekI32 v, unsigned flags);

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
    /* ALREADY OURS IN THIS DISPATCH TABLE, and this check is what makes
       installing more than once safe rather than fatal. Saving `old`
       here would point the chain at our own shim, and the first call
       through it would loop until the machine stopped. With the check,
       a second install is a no-op under a system-wide table and a real
       install under a per-context one - correct either way, which is
       the point, because which one this machine has is exactly what is
       not yet known (docs/open-issues.md, the act plane's contexts). */
    if (old == shim) {
        *patches |= (NowPeekU32)bit;
        return;
    }
    *saved = old;
    NSetTrapAddress((UniversalProcPtr)shim, trap, ToolTrap);
    *patches |= (NowPeekU32)bit;
}

/*
 * WHY THIS IS NO LONGER ONE-SHOT, 2026-08-02.
 *
 * It was `static int installed`, run once per boot. Measured on an
 * emulated Power Mac G4: `actselftest` abi-agrees inside NOW's own
 * application and answers `act-no-patch` inside the Finder and inside
 * SimpleText, on the same boot, twice each. For the selftest the arm
 * point is negative - unguarded - and the A5 matches, so if the
 * trampoline had run it would have set `fired`. It did not: the
 * resident called MenuSelect from its own 68K code, inside a foreign
 * application, and its own patch was not in the dispatch path.
 *
 * The install always landed in NOW's context, because NOW's application
 * is the one pumping the wire the request arrived on - fronting another
 * application cannot move it. So "installed once, in a Carbon
 * application's context" is the one condition every failing measurement
 * shares.
 *
 * Running it on every armed pass costs six NGetTrapAddress calls while
 * the plane is armed, and nothing at all while it is not: the arm bit
 * still gates the whole plane, so a machine that never opens the mirror
 * still has an unpatched trap table, which is the charter property this
 * change had to keep.
 */
static void act_install(NowPeekActCell *cell)
{
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
    /* THE ONE-WAY DOOR, written down where a person can see it.
       ------------------------------------------------------------------
       This is the only bit in `rest_state` that never clears. Disarming
       the plane makes all six trampolines chain straight through, so the
       machine behaves as it would with no extension — but the patches are
       still in the dispatch table and cannot be taken out, because
       another extension may have chained behind ours and removing a link
       from the middle of a chain is how a Macintosh jumps into freed
       code.

       A capability bit cannot carry this and neither can `arm_active`:
       one says the plane exists and the other says it is armed, while the
       true and durable fact is that THIS MACHINE, THIS BOOT, has had its
       trap table modified and will until it restarts. That is the fact a
       person deciding whether to keep the extension installed is owed. */
    if (gNowActTable != NULL && cell->patches != 0) {
        gNowActTable->rest_state |= (NowPeekU16)kNowPeekRestActPatched;
    }
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

/* Prepare one Dialog Manager press in the process that owns the dialog.
   The request names the item twice: its 1-based DITL number and the
   observation-minted ControlHandle. Requiring GetDialogItem to return that
   SAME handle is the identity guard; an item number alone can silently move
   when a dialog rebuilds its list. */
static unsigned long act_prepare_ditem_press(NowPeekActCell *cell)
{
    WindowPtr     w = (WindowPtr)(unsigned long)cell->text_window;
    DialogPtr     d = (DialogPtr)w;
    Handle        item_h = NULL;
    ControlHandle control;
    Rect          box;
    Point         pt;
    GrafPtr       save;
    short         type = 0;
    short         base;
    short         item = (short)cell->text_item;

    if (w == NULL
        || !now_act_window_is_ours((unsigned long)LMGetWindowList(),
                                   (unsigned long)w, act_next_window, NULL)) {
        return kNowPeekActErrNotOurWindow;
    }
    if (((WindowPeek)w)->windowKind != dialogKind) {
        return kNowPeekActErrNotDialog;
    }
    if (item < 1 || item > CountDITL(d)) {
        return kNowPeekActErrNoItem;
    }
    GetDialogItem(d, item, &type, &item_h, &box);
    cell->text_item_type = (NowPeekI32)type;
    base = (short)(type & ~itemDisable);
    if (base != ctrlItem + btnCtrl
        && base != ctrlItem + chkCtrl
        && base != ctrlItem + radCtrl) {
        return kNowPeekActErrNotControlItem;
    }
    if (item_h == NULL
        || (unsigned long)item_h != (unsigned long)cell->control_handle) {
        return kNowPeekActErrItemMismatch;
    }
    control = (ControlHandle)item_h;
    if ((type & itemDisable) != 0
        || !((**control).contrlVis)
        || (**control).contrlHilite == 255) {
        return kNowPeekActErrItemDisabled;
    }

    /* DITL boxes are local to the dialog port; event `where` is global. */
    pt.h = (short)((box.left + box.right) / 2);
    pt.v = (short)((box.top + box.bottom) / 2);
    GetPort(&save);
    SetPort((GrafPtr)w);
    LocalToGlobal(&pt);
    SetPort(save);
    cell->click_h = (NowPeekI32)pt.h;
    cell->click_v = (NowPeekI32)pt.v;
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
 * THE PLANE POSTS ITS OWN PRESS, and this is the one place NOW's port
 * diverges from upstream's design rather than merely renaming it.
 *
 * Upstream's application posts the click, because upstream's application
 * is a classic PPC binary. NOW's is CARBON, and PPostEvent and the
 * low-memory mouse globals are CALL_NOT_IN_CARBON - so the application
 * literally cannot queue an event whose `where` it controls. That is not
 * a workaround, it is the better place for it anyway:
 *
 *   - The press is queued from INSIDE the target process, at the moment
 *     of arming, so there is no window between "armed" and "pressed"
 *     during which a user's own click could arrive first.
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
static int act_post_click(NowPeekActCell *cell)
{
    Point    pt;
    EvQElPtr down = NULL;
    EvQElPtr up = NULL;

    if (cell->op == (NowPeekU32)kNowPeekActOpMenu) {
        /* The menu press and the menu guard are the same point by
           construction - the guard compares against what we queue. */
        pt.h = (short)cell->arm_point_h;
        pt.v = (short)cell->arm_point_v;
    } else {
        pt.h = (short)cell->click_h;
        pt.v = (short)cell->click_v;
    }

    /* Where the pointer is, and - new with P8 - where it LOOKS like it
       is. This was three low-memory writes with a comment calling them
       cosmetic; the writes are unchanged and still are cosmetic for the
       click itself, whose `where` is stamped per event below. What is
       not cosmetic is the second half P8 adds: the drawn cursor moving
       to the point we are about to click on, so that a screendump is
       evidence of WHERE we acted, software that draws relative to the
       pointer stops being a special case, and a person watching sees a
       machine being operated rather than a possessed one.

       `owned` is 0, and that is the whole safety story: if the pointer
       has moved since we last placed it - a person at the machine - P8
       declines to move the sprite for a second and counts the decline,
       while these three writes still happen so the click lands exactly
       where the act says it does. The act never yields; only the picture
       does. */
    (void)now_ext_cursor_place((NowPeekI32)pt.h, (NowPeekI32)pt.v, 0u);

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

/* THE PRESS EVENT, and without it nothing on this machine ever enters a
 * tracking loop.
 *
 * Found by driving, 2026-08-07, and it is the third break in one gesture:
 * the vehicle wrote MBState down, moved the pointer, ticked 120 times and
 * released on its deadline, and the Finder did not move the icon by a
 * pixel. It could not have. Writing MBState is what a tracking loop
 * READS once it is running; it is not what STARTS one. An application
 * begins a drag because a mouseDown arrived through GetNextEvent, it
 * hit-tested the point, and it called DragGrayRgn - and no mouseDown was
 * ever queued.
 *
 * That was invisible because the plane's other users do not need one.
 * ctlact's patch answers TrackControl for a handle the request names, so
 * the target is already inside a loop when the button matters; a drag
 * starts from outside one.
 *
 * The mirror image of act_settle_drag_mouseup below - one event, `where`
 * stamped on the queue element rather than left to the live mouse, in the
 * target's own context, which is where this serve already runs. Unlike
 * act_post_click it posts ONLY the down: the up is what the vehicle's
 * deadline owes and it must not be queued here, or the gesture would end
 * the instant it began.
 *
 * A refused queue is NOT best-effort, and that asymmetry with the mouseUp
 * is deliberate. There, the button is already up and no machine is
 * wedged; here, failing quietly would leave the button down with nothing
 * tracking it - which is precisely the state this whole plane exists to
 * make impossible. So the caller abandons the gesture instead. */
static int act_post_drag_mousedown(NowPeekActCell *cell)
{
    EvQElPtr down = NULL;
    Point    pt;

    pt.h = (short)cell->click_h;
    pt.v = (short)cell->click_v;
    if (PPostEvent(mouseDown, 0, &down) != noErr || down == NULL) {
        return 0;
    }
    down->evtQWhere = pt;
    down->evtQModifiers = 0;
    return 1;
}

/* Settle the mouseUp the drag vehicle could not queue.
 *
 * The button itself went up at interrupt time, in now_ext_drag_tick,
 * where nothing could refuse it. This is the OTHER half: PPostEvent
 * needs the target's own context, and this is the first moment there has
 * been one - the tracking loop saw the button rise, returned, and handed
 * the application back to GetNextEvent, which is where we are standing.
 *
 * Best-effort by design. A refused queue is recorded by leaving the debt
 * cleared anyway, because the alternative is retrying forever against an
 * application that may simply never want the event; the button is
 * already up and no machine is wedged either way. That asymmetry is the
 * point of splitting the two halves at all.
 *
 * Only the process the drag was addressed to may settle it. Without that
 * check the FIRST application to pump after a drag ended would receive a
 * mouseUp belonging to somebody else's gesture. */
static void act_settle_drag_mouseup(NowPeekTable *table, unsigned long a5)
{
    NowPeekDragCell *drag = now_ext_drag_cell(table);
    EvQElPtr up = NULL;
    Point pt;

    if (drag == NULL || drag->pending_mouseup == 0) {
        return;
    }
    if (drag->target_a5 != (NowPeekU32)a5) {
        return;
    }
    drag->pending_mouseup = 0;
    pt.h = (short)drag->at_h;
    pt.v = (short)drag->at_v;
    if (PPostEvent(mouseUp, 0, &up) == noErr && up != NULL) {
        up->evtQWhere = pt;
        up->evtQModifiers = 0;
    }
}

/* The system Application menu is owned by the Process Manager, not by the
   application whose MenuSelect the generic menu act can answer. Queue the
   two public keyboard equivalents from inside that exact application's A5
   world instead. PPostEvent is unavailable to the Carbon client and is why
   this small foreign-context effect belongs in the resident plane. */
#define kNowActVisibilityKeyWaitTicks 3UL

static int act_post_visibility_key(NowPeekActCell *cell)
{
    EvQElPtr down = NULL;
    EvQElPtr up = NULL;
    unsigned long start;
    UInt32 message = ((UInt32)4 << 8) | (UInt32)'h';
    short modifiers = cmdKey;

    if (cell->item_index == kNowPeekActVisibilityHideOthers) {
        modifiers |= optionKey;
    }
    if (PPostEvent(keyDown, message, &down) != noErr || down == NULL) {
        return 0;
    }
    down->evtQModifiers = modifiers;

    start = (unsigned long)LMGetTicks();
    while ((unsigned long)LMGetTicks() - start
           < kNowActVisibilityKeyWaitTicks) {
        /* Bounded: the modifier stamp was measured unreliable when the
           up event followed in the same tick. This hook cannot yield. */
    }
    if (PPostEvent(keyUp, message, &up) == noErr && up != NULL) {
        up->evtQModifiers = modifiers;
    }
    return 1;
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
    unsigned long   ticks;
    int             verdict;
    int             identity;

    /* Before the armed-cell gate, and deliberately. A mouseUp owed by a
       drag that has ALREADY ended is not a request: there may be no act
       pending at all, and there certainly is no lease if the host that
       began the gesture is the thing that died. It is gated on the
       drag's own target_a5 instead. */
    act_settle_drag_mouseup(table, (unsigned long)LMGetCurrentA5());
    if (cell == NULL) {
        return;
    }
    gNowActTable = table;
    /* In-context installation, on the first armed pass - the plane model
       (docs/resident-components.md). Before this, a machine that never
       armed the plane has an unpatched trap table. */
    act_install(cell);

    a5 = (unsigned long)LMGetCurrentA5();
    ticks = (unsigned long)LMGetTicks();
    identity = now_act_v2_begin(table, a5, ticks);
    if (identity == 0) {
        return;
    }
    if (identity < 0) {
        cell->seq++;
        now_act_serve_commit(cell, cell->error);
        return;
    }
    verdict = now_act_serve_begin(cell, a5, ticks);
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
        now_act_v2_note(table, kNowPeekActStageFired,
                        (unsigned long)LMGetTicks());
        break;
    case kNowActServeSelect:
        SelectWindow((WindowPtr)(unsigned long)cell->window_ptr);
        cell->fired = 1;
        cell->armed = kNowPeekActArmNone;
        cell->find_window_fired = 0;
        now_act_v2_note(table, kNowPeekActStageFired,
                        (unsigned long)LMGetTicks());
        break;
    case kNowActServeText:
        error = act_serve_text(cell, cell->op == kNowPeekActOpTextSet);
        if (error == kNowPeekActErrNone) {
            now_act_v2_note(table, kNowPeekActStageFired,
                            (unsigned long)LMGetTicks());
        }
        break;
    case kNowActServeSelfTest:
        error = act_serve_selftest(cell);
        if (error == kNowPeekActErrNone) {
            now_act_v2_note(table, kNowPeekActStageFired,
                            (unsigned long)LMGetTicks());
        }
        break;
    case kNowActServeDialogItem:
        error = act_prepare_ditem_press(cell);
        if (error == kNowPeekActErrNone) {
            if (!act_post_click(cell)) {
                error = kNowPeekActErrPostFailed;
            } else {
                /* No patched question follows: DialogSelect/ModalDialog
                   consumes the queued mouseDown in the application. */
                cell->fired = 1;
                cell->armed = kNowPeekActArmNone;
                now_act_v2_note(table, kNowPeekActStageFired,
                                (unsigned long)LMGetTicks());
            }
        }
        break;
    case kNowActServeDragPress:
        /* The session nonce is the caller's, carried in control_handle -
           an existing 32-bit field with no meaning for this op, which is
           what the accretive rule asks for instead of a new one. The two
           deadlines ride in win_h / win_v for the same reason, and the
           resident clamps both regardless of what arrived. */
        if (!now_ext_drag_press(table, cell->control_handle, (NowPeekU32)a5,
                                cell->click_h, cell->click_v,
                                (NowPeekU32)cell->win_h,
                                (NowPeekU32)cell->win_v)) {
            NowPeekDragCell *drag = now_ext_drag_cell(table);
            /* Two refusals that must not collapse into one: no vehicle at
               all is a different resident, a busy vehicle is a retry. */
            error = (drag == NULL) ? kNowPeekActErrDragNoVehicle
                                   : kNowPeekActErrDragBusy;
        } else if (!act_post_drag_mousedown(cell)) {
            /* The button is down and nothing would ever track it. Take
               the gesture back rather than hand out a session for a
               drag no application has been told about. */
            now_ext_drag_abandon(table);
            error = kNowPeekActErrPostFailed;
        } else {
            cell->fired = 1;
            now_act_v2_note(table, kNowPeekActStageFired,
                            (unsigned long)LMGetTicks());
        }
        break;

    case kNowActServeVisibility:
        if (!act_post_visibility_key(cell)) {
            error = kNowPeekActErrPostFailed;
        } else {
            cell->fired = 1;
            cell->armed = kNowPeekActArmNone;
            now_act_v2_note(table, kNowPeekActStageFired,
                            (unsigned long)LMGetTicks());
        }
        break;
    case kNowActServeArmed:
        now_act_v2_note(table, kNowPeekActStageArmed,
                        (unsigned long)LMGetTicks());
        /* Armed in the target's own context, which proves the target is
           alive and pumping before any patch goes live. Then the click
           that makes the application call the patched trap. */
        if (!act_post_click(cell)) {
            error = kNowPeekActErrPostFailed;
        }
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
    if (error != kNowPeekActErrNone) {
        now_act_v2_note(table, kNowPeekActStageRefused,
                        (unsigned long)LMGetTicks());
    }
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
    NowPeekActCell *cell = now_act_armed_cell(gNowActTable);
    long answer;

    answer = now_act_menu_answer(cell, (unsigned long)LMGetCurrentA5(),
                                 start_pt, (unsigned long)LMGetTicks());
    if (answer != 0) {
        now_act_v2_note(gNowActTable, kNowPeekActStageFired,
                        (unsigned long)LMGetTicks());
    }
    return answer;
}

short now_act_patch_trackcontrol(void *control, void *action_proc)
{
    NowPeekActCell  *cell = now_act_armed_cell(gNowActTable);
    unsigned long    call = 0;
    short            part;

    part = now_act_control_answer(cell, (unsigned long)LMGetCurrentA5(),
                                  (unsigned long)control,
                                  (unsigned long)action_proc,
                                  (unsigned long)LMGetTicks(), &call);
    if (part == 0) {
        return 0;
    }
    now_act_v2_note(gNowActTable, kNowPeekActStageFired,
                    (unsigned long)LMGetTicks());
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
    {
        long answer = now_act_grow_answer(cell, a5, (unsigned long)window,
                                          (unsigned long)LMGetTicks());
        if (answer != 0) {
            now_act_v2_note(gNowActTable, kNowPeekActStageFired,
                            (unsigned long)LMGetTicks());
        }
        return answer;
    }
}

short now_act_patch_trackbox(void *window, long part)
{
    NowPeekActCell *cell = now_act_armed_cell(gNowActTable);
    unsigned long   a5 = (unsigned long)LMGetCurrentA5();

    now_act_trap_hit(cell, 2, a5);
    {
        short answer = (short)now_act_trackbox_answer(
            cell, a5, (unsigned long)window, part,
            (unsigned long)LMGetTicks());
        if (answer != 0) {
            now_act_v2_note(gNowActTable, kNowPeekActStageFired,
                            (unsigned long)LMGetTicks());
        }
        return answer;
    }
}

short now_act_patch_trackgoaway(void *window, unsigned long point)
{
    NowPeekActCell *cell = now_act_armed_cell(gNowActTable);
    unsigned long   a5 = (unsigned long)LMGetCurrentA5();

    (void)point;
    now_act_trap_hit(cell, 3, a5);
    {
        short answer = (short)now_act_goaway_answer(
            cell, a5, (unsigned long)window, (unsigned long)LMGetTicks());
        if (answer != 0) {
            now_act_v2_note(gNowActTable, kNowPeekActStageFired,
                            (unsigned long)LMGetTicks());
        }
        return answer;
    }
}
