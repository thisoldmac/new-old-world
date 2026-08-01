/*
 * portal.c - the Portal INIT: an in-process agent for every application.
 *
 * AXPeek established that a GNEFilter INIT runs inside every application's
 * context, with that process's A5 world current, and used it to READ the
 * per-process Toolbox roots that are invisible from outside. The Portal uses the
 * same window to ACT.
 *
 * Why that is the whole game: every mechanism for driving a foreign application
 * from OUTSIDE it runs into the same wall — per-process low memory it cannot
 * see, tracking loops it cannot enter, and geometry the guest never reports, so
 * coordinates have to be guessed. Inside the process none of those exist. This
 * first operation is the smallest proof of that: ask the target's own Menu
 * Manager where its menu items are, which is unanswerable from outside and
 * trivial from in here.
 *
 * Provenance: P-DOC. Low-memory addresses (CurrentA5 0x0904, Ticks 0x016A) and
 * the MDEF message protocol are from Inside Macintosh (Toolbox Essentials, the
 * Menu Manager). Nothing here comes from a disassembly.
 *
 * Safety posture, stated plainly: this runs in other applications' contexts on a
 * system with no memory protection, so a mistake here takes THEIR app down, or
 * the machine. That is acceptable on a disposable emulator clone and is not
 * acceptable anywhere else yet. The code stays allocation-free in the hook, does
 * nothing at all unless a request names the current A5 world, and touches only
 * handles the Menu Manager itself just handed it.
 */

#include "ptshared.h"

#include <stddef.h>

#include <Retro68Runtime.h>

#include <Gestalt.h>
#include <MacMemory.h>
#include <Menus.h>
#include <Controls.h>
#include <Dialogs.h>
#include <TextEdit.h>
#include <Quickdraw.h>
#include <MacWindows.h>
#include <Resources.h>
#include <LowMem.h>
#include <Traps.h>
#include <OSUtils.h>

/* Documented low-memory globals (Inside Macintosh). CurrentA5 identifies the
 * process we are currently running as; Ticks stamps the reply. */
#define LM_CURRENT_A5 (*(volatile unsigned long *)0x0904UL)
#define LM_TICKS      (*(volatile unsigned long *)0x016AUL)

/* The MDEF's documented entry: message, the menu, a rect, a hit point, and the
 * item number. For mCalcItemMsg the definition procedure fills `menuRect` with
 * the rectangle enclosing item `whichItem`. */
typedef pascal void (*MDEFProc)(short message, MenuHandle theMenu,
                                Rect *menuRect, Point hitPt, short *whichItem);

/* The Control Manager's action procedure: what actually scrolls a scroll bar
 * while it is being tracked. */
typedef pascal void (*PTActionProc)(ControlHandle theControl, short part);

PTSharedPtr           gPortal = NULL;
GetNextEventFilterUPP gOldGNEFilter = NULL;
/* The original _MenuSelect, for the patch to chain to. Resident like the rest. */
void                 *gOldMenuSelect = NULL;
/* The original _TrackControl, likewise. */
void                 *gOldTrackControl = NULL;
/* The four window traps PT_OP_WINDOW_ACT answers. */
void                 *gOldFindWindow = NULL;
void                 *gOldGrowWindow = NULL;
void                 *gOldTrackBox = NULL;
void                 *gOldTrackGoAway = NULL;

extern void pt_gne_filter(void);
extern void pt_menuselect_patch(void);
extern void pt_trackcontrol_patch(void);
extern void pt_findwindow_patch(void);
extern void pt_growwindow_patch(void);
extern void pt_trackbox_patch(void);
extern void pt_trackgoaway_patch(void);

/* _MenuSelect. Documented trap number (Inside Macintosh, the Menu Manager). */
#define kMenuSelectTrap 0xA93D

/* ---- the server, called in EVERY process's context ------------------------ */

/* Fill the reply with the target's real per-item rects, by asking the menu's own
 * definition procedure. A standard menu's items are NOT uniform rows — a
 * separator is drawn shorter — which is exactly why computing them outside the
 * process put selection on the wrong item. */
static void pt_serve_menu_geometry(PTSharedPtr p)
{
    MenuHandle mh;
    Handle     mdef;
    MDEFProc   proc;
    Rect       r;
    Point      pt;
    short      item;
    short      count;
    short      i;
    SignedByte saveState;

    mh = GetMenuHandle((short)p->menuID);
    if (mh == NULL) {
        p->error = PT_ERR_NO_MENU;
        p->status = PT_STATUS_ERROR;
        return;
    }

    mdef = (Handle)(*mh)->menuProc;
    if (mdef == NULL || *mdef == NULL) {
        p->error = PT_ERR_NO_MDEF;
        p->status = PT_STATUS_ERROR;
        return;
    }

    p->menuWidth = (*mh)->menuWidth;
    p->menuHeight = (*mh)->menuHeight;

    count = CountMItems(mh);
    if (count > PT_MAX_ITEMS) {
        count = PT_MAX_ITEMS;
    }

    /* The MDEF may be a purgeable resource; lock it across the calls so the
     * pointer we call through cannot move underneath us. */
    saveState = HGetState(mdef);
    HLock(mdef);
    proc = (MDEFProc)*mdef;

    pt.h = 0;
    pt.v = 0;
    for (i = 1; i <= count; i++) {
        item = i;
        /* Seed the rect with the menu's own box: the definition procedure
         * answers in the coordinate system it is handed. */
        r.left = 0;
        r.top = 0;
        r.right = (*mh)->menuWidth;
        r.bottom = (*mh)->menuHeight;
        proc(mCalcItemMsg, mh, &r, pt, &item);
        p->items[i - 1].top = r.top;
        p->items[i - 1].left = r.left;
        p->items[i - 1].bottom = r.bottom;
        p->items[i - 1].right = r.right;
    }
    HSetState(mdef, saveState);

    p->itemCount = count;
    p->error = PT_ERR_NONE;
    p->status = PT_STATUS_DONE;
}

/* ---- PT_OP_WINDOW_ACT ----------------------------------------------------- */

/*
 * Serve a window request in the target's own context.
 *
 * Three of the four sub-ops only ARM here — the same discipline MENU_INVOKE and
 * CONTROL_INVOKE use, and for the same reason: arming inside the target proves
 * the target is alive and pumping before any patch goes live, and it means a
 * patch is only ever armed while the process it names is actually running.
 *
 * MOVE is served outright, because there is nothing to arm. `DragWindow` is
 * `pascal void` — it does the move itself and hands the application nothing
 * back — so there is no question to answer and no application code that runs
 * after it. Calling MoveWindow here IS what DragWindow would have done, minus
 * the tracking loop and the mouse motion the tracking loop needs. (That motion
 * is the whole reason drag was emulator-only: injecting it needs QMP. Nothing
 * in this path injects motion.)
 *
 * Safety: MoveWindow is a Window Manager call made at GNEFilter time, which is
 * inside the application's own GetNextEvent — the same place the MDEF call in
 * PT_OP_MENU_GEOMETRY is made, and the moment the application would itself have
 * been handling the click. It repaints and queues an update event; it does not
 * re-enter the Event Manager. `front` is false so the move does not also raise
 * the window: one request, one effect.
 *
 * MoveWindow's h/v are documented (Inside Macintosh: Macintosh Toolbox
 * Essentials, the Window Manager) as the new global position of the upper-left
 * corner of the window's CONTENT region — which is the same rectangle the
 * AXPeek walk reports, since `ax_read_window` reads contRgn (WindowRecord+118).
 * Request and oracle therefore speak about the same corner. That is a claim
 * about a document, so it is checked by measurement: `winact` re-reads the
 * window's own rect afterwards and the trial rate is what settles it.
 */
static void pt_serve_window_act(PTSharedPtr p)
{
    if (p->windowPtr == 0) {
        p->error = PT_ERR_NO_WINDOW;
        p->status = PT_STATUS_ERROR;
        return;
    }

    switch (p->windowOp) {
    case PT_WIN_MOVE:
        MoveWindow((WindowPtr)(unsigned long)p->windowPtr,
                   (short)p->winH, (short)p->winV, false);
        p->armed = PT_ARM_NONE;
        p->fired = 1;                 /* the effect happened here, in-context */
        p->findWindowFired = 0;       /* no patch was involved                */
        p->error = PT_ERR_NONE;
        p->status = PT_STATUS_DONE;
        return;

    case PT_WIN_RESIZE:
        if (gOldFindWindow == NULL || gOldGrowWindow == NULL) {
            p->error = PT_ERR_NO_WIN_PATCH;
            p->status = PT_STATUS_ERROR;
            return;
        }
        break;

    case PT_WIN_ZOOM:
        if (gOldFindWindow == NULL || gOldTrackBox == NULL) {
            p->error = PT_ERR_NO_WIN_PATCH;
            p->status = PT_STATUS_ERROR;
            return;
        }
        if (p->zoomPart != PT_IN_ZOOM_IN && p->zoomPart != PT_IN_ZOOM_OUT) {
            p->error = PT_ERR_BAD_WINDOW_OP;
            p->status = PT_STATUS_ERROR;
            return;
        }
        break;

    case PT_WIN_CLOSE:
        if (gOldFindWindow == NULL || gOldTrackGoAway == NULL) {
            p->error = PT_ERR_NO_WIN_PATCH;
            p->status = PT_STATUS_ERROR;
            return;
        }
        break;

    default:
        p->error = PT_ERR_BAD_WINDOW_OP;
        p->status = PT_STATUS_ERROR;
        return;
    }

    p->fired = 0;
    p->findWindowFired = 0;
    p->armed = PT_ARM_READY;
    p->error = PT_ERR_NONE;
    p->status = PT_STATUS_DONE;
}

/* ---- the text ops (PT_OP_TEXT_GET / PT_OP_TEXT_SET) ------------------------
 *
 * These need no trap patch. A TextEdit record and a dialog's item list are not
 * things the application is about to ASK us about — they are per-process roots
 * that simply are not reachable from outside the process and are ordinary
 * memory from in here. So the hook does the work directly, which also means
 * there is no armed window during which a user's own call could be answered.
 *
 * What replaces the trap patch's identity check is a stricter one, because the
 * hazard here is writing to the WRONG OBJECT rather than at the wrong moment:
 * the request must name a window, and that window must be in THIS process's
 * window list. Every kind then adds its own second check. Nothing is written on
 * the strength of "a request is pending in this process".
 *
 * Provenance for everything touched below: WindowRecord.windowKind and
 * WindowRecord.nextWindow (MacWindows.h); dialogKind == 2 (MacWindows.h:433);
 * DialogRecord.items / .textH / .editField (Dialogs.h:153-160); editText == 16
 * and statText == 8 (Dialogs.h:98-99); TERec.teLength / .hText / .inPort /
 * .viewRect (TextEdit.h:231-262). No offset here is inferred.
 */

/* Is this WindowPtr one of OUR windows? The window list head is a documented
 * per-process low-memory global, so walking it proves the named window belongs
 * to the process we are currently running as — which is exactly the claim a
 * write needs and the claim `armed in this process` does not make.
 *
 * Bounded, like every other walk in this project: a corrupt nextWindow chain
 * must cost us a loop count, not the machine. */
#define PT_MAX_WINDOW_WALK 64

static int pt_window_is_ours(void *w)
{
    WindowPeek probe;
    int        guard;

    if (w == NULL) {
        return 0;
    }
    probe = (WindowPeek)LMGetWindowList();
    for (guard = 0; probe != NULL && guard < PT_MAX_WINDOW_WALK; guard++) {
        if ((void *)probe == w) {
            return 1;
        }
        probe = probe->nextWindow;
    }
    return 0;
}

/* Could this address plausibly be a handle into THIS application's heap, with
 * at least `need` bytes of record behind it?
 *
 * Measured 2026-07-31, and the reason this function exists: `textset` with a
 * caller-supplied handle of 1234 did NOT come back as `bad_handle`. It timed
 * out, and it took SimpleText's open dialog with it. The identity check —
 * `(**te).inPort == w` — is two dereferences of an arbitrary integer, and it
 * was running BEFORE anything had established that the integer addresses
 * memory at all. On a system with no memory protection that is our mistake
 * taking somebody else's application down, which is the exact hazard
 * PORTAL-PLAN.md names and the exact thing the hook is supposed not to do.
 *
 * So bound it first, with the discipline this project already applies to the
 * AXPeek and QDPeek blocks: range-check against the zone's own limits before
 * dereferencing anything. ApplZone is the documented per-process heap zone
 * (LMGetApplZone, LowMem.h:1099); `bkLim` is the zone's high limit
 * (Zone.bkLim, MacMemory.h:96). A master pointer lives in the same zone, so
 * both the handle and the block it points to must fall inside it.
 *
 * This is a PLAUSIBILITY check, not a proof: an in-zone address that is not a
 * TEHandle still gets past it, which is why the inPort test remains and
 * remains the identity guard. What this rules out is the wild read. */
static int pt_handle_in_heap(void *h, unsigned long need)
{
    THz           zone = LMGetApplZone();
    unsigned long lo, hi, addr, master;

    if (zone == NULL || h == NULL) {
        return 0;
    }
    lo = (unsigned long)zone;
    hi = (unsigned long)zone->bkLim;
    addr = (unsigned long)h;
    if (hi <= lo || need == 0 || (hi - lo) < need) {
        return 0;
    }
    if (addr < lo || addr > hi - sizeof(void *)) {
        return 0;
    }
    master = *(unsigned long *)addr;        /* in-zone: safe to read */
    if (master < lo || master > hi - need) {
        return 0;
    }
    return 1;
}

/* How much of a TERec we actually touch. NOT sizeof(TERec): the header
 * declares lineStarts[16001] (TextEdit.h:262), so sizeof is ~32 KB while a
 * real record is allocated to fit its line count. Everything read here —
 * viewRect, teLength, hText, inPort — lives below lineStarts. */
#define PT_TEREC_NEED ((unsigned long)offsetof(TERec, lineStarts))

/* Copy a TERec's text into the reply. `teLength` is the record's own count and
 * `hText` its text handle (TextEdit.h) — we take the shorter of that and our
 * buffer, and report the TRUE length separately, so a long document reads as
 * truncated rather than as a short document. */
static void pt_te_read(PTSharedPtr p, TEHandle te)
{
    Handle     h = (**te).hText;
    long       len = (long)(**te).teLength;
    long       take = len;
    SignedByte saveState;

    p->textTE = (uint32_t)(unsigned long)te;
    p->textLength = (int32_t)len;
    p->textBufLength = 0;
    /* hText comes out of a record we have only bounded, not proved — so it
     * gets the same treatment before it is locked and copied from. */
    if (h == NULL || len <= 0 || !pt_handle_in_heap(h, (unsigned long)len)
        || *h == NULL) {
        return;
    }
    if (take > PT_TEXT_MAX) {
        take = PT_TEXT_MAX;
    }
    saveState = HGetState(h);
    HLock(h);
    BlockMoveData(*h, p->textBuf, take);
    HSetState(h, saveState);
    p->textBufLength = (int32_t)take;
}

/* Resolve the request to a TEHandle, with the identity check its kind demands.
 * Returns NULL and sets p->error on any failure — never a best guess. */
static TEHandle pt_text_resolve_te(PTSharedPtr p, WindowPtr w)
{
    TEHandle te;

    if (p->textKind == PT_TEXT_KIND_DIALOG_TE) {
        if (((WindowPeek)w)->windowKind != dialogKind) {
            p->error = PT_ERR_NOT_DIALOG;
            return NULL;
        }
        te = ((DialogPeek)w)->textH;
        if (te == NULL || *te == NULL) {
            p->error = PT_ERR_BAD_TE;
            return NULL;
        }
        return te;
    }

    /* PT_TEXT_KIND_TE: the caller named the handle, so the handle has to prove
     * it belongs to the window the caller also named. A TEHandle from another
     * process fails here, because its inPort is not one of our windows. */
    te = (TEHandle)(unsigned long)p->textHandle;
    /* Bound BEFORE dereferencing. Order matters and is the whole fix: this
     * used to read `*te` first, and an arbitrary integer got two levels of
     * dereference before anything checked it addressed memory. */
    if (!pt_handle_in_heap((void *)te, PT_TEREC_NEED) || *te == NULL) {
        p->error = PT_ERR_BAD_TE;
        return NULL;
    }
    if ((void *)(**te).inPort != (void *)w) {
        p->error = PT_ERR_BAD_TE;
        return NULL;
    }
    return te;
}

/* TESetText does not display the new text (Inside Macintosh: Text, TextEdit) —
 * so a set that stops there leaves the screen showing the old document, which
 * is the single most misleading failure this op can have. Recalculate the line
 * breaks, redraw the view, and ALSO invalidate it so the application's own
 * update path runs on its next pass and agrees with us.
 *
 * The port is saved and restored: we are running inside the app's GetNextEvent,
 * and leaving a different port current would be a defect with no obvious
 * cause. */
static void pt_te_redraw(TEHandle te, WindowPtr w)
{
    GrafPtr savePort;
    Rect    view = (**te).viewRect;

    GetPort(&savePort);
    SetPort((GrafPtr)w);
    TECalText(te);
    EraseRect(&view);
    TEUpdate(&view, te);
    InvalRect(&view);
    SetPort(savePort);
}

static void pt_serve_text(PTSharedPtr p, int isSet)
{
    WindowPtr w = (WindowPtr)(unsigned long)p->textWindow;
    TEHandle  te;

    p->textBufLength = 0;
    p->textItemType = 0;
    p->textTE = 0;

    /* The identity check, before anything is read and long before anything is
     * written. */
    if (!pt_window_is_ours((void *)w)) {
        p->error = PT_ERR_TEXT_NO_WINDOW;
        p->status = PT_STATUS_ERROR;
        return;
    }

    if (p->textKind == PT_TEXT_KIND_DITEM) {
        DialogPtr d = (DialogPtr)w;
        Handle    itemH = NULL;
        Rect      box;
        short     type = 0;
        Str255    str;
        short     item = (short)p->textItem;

        if (((WindowPeek)w)->windowKind != dialogKind) {
            p->error = PT_ERR_NOT_DIALOG;
            p->status = PT_STATUS_ERROR;
            return;
        }
        if (item < 1 || item > CountDITL(d)) {
            p->error = PT_ERR_NO_ITEM;
            p->status = PT_STATUS_ERROR;
            return;
        }
        GetDialogItem(d, item, &type, &itemH, &box);
        p->textItemType = (int32_t)type;
        /* itemDisable (128) rides in the high bit of the type byte
         * (Dialogs.h:103); mask it off before comparing. */
        if (((type & ~itemDisable) != editText)
            && ((type & ~itemDisable) != statText)) {
            p->error = PT_ERR_NOT_TEXT;
            p->status = PT_STATUS_ERROR;
            return;
        }
        if (itemH == NULL) {
            p->error = PT_ERR_NO_ITEM;
            p->status = PT_STATUS_ERROR;
            return;
        }
        if (isSet) {
            long n = (long)p->textLength;

            if (n < 0) {
                n = 0;
            }
            if (n > PT_TEXT_MAX) {
                n = PT_TEXT_MAX;
            }
            str[0] = (unsigned char)n;
            if (n > 0) {
                BlockMoveData(p->textBuf, &str[1], n);
            }
            /* SetDialogItemText both stores and DRAWS the item (Inside
             * Macintosh: Toolbox Essentials, the Dialog Manager), so the
             * dialog case needs no invalidation of our own. */
            SetDialogItemText(itemH, str);
            /* If this item is the one the Dialog Manager currently has open
             * for editing, its live TERec — DialogRecord.textH — holds a copy
             * that SetDialogItemText did not touch, and the next keystroke
             * would resurrect the old string. editField is the item number
             * MINUS ONE (Dialogs.h:157, and Inside Macintosh). Re-selecting
             * the item makes the Dialog Manager reload it from the item
             * handle. */
            if (((DialogPeek)d)->editField == (short)(item - 1)) {
                SelectDialogItemText(d, item, 0, 32767);
            }
        }
        /* Read back from the OBJECT, on both paths: for GET this is the
         * answer, and for SET it is the only evidence worth reporting — the
         * verb's own say-so is what four retracted findings here were made
         * of. */
        GetDialogItemText(itemH, str);
        p->textLength = (int32_t)str[0];
        p->textBufLength = (int32_t)(str[0] > PT_TEXT_MAX
                                     ? PT_TEXT_MAX : str[0]);
        if (p->textBufLength > 0) {
            BlockMoveData(&str[1], p->textBuf, p->textBufLength);
        }
        if (((WindowPeek)w)->windowKind == dialogKind) {
            p->textTE = (uint32_t)(unsigned long)((DialogPeek)d)->textH;
        }
        p->error = PT_ERR_NONE;
        p->status = PT_STATUS_DONE;
        return;
    }

    if (p->textKind != PT_TEXT_KIND_TE
        && p->textKind != PT_TEXT_KIND_DIALOG_TE) {
        p->error = PT_ERR_TEXT_KIND;
        p->status = PT_STATUS_ERROR;
        return;
    }

    te = pt_text_resolve_te(p, w);
    if (te == NULL) {
        p->status = PT_STATUS_ERROR;      /* error already named */
        return;
    }

    if (isSet) {
        long n = (long)p->textLength;

        if (n < 0) {
            n = 0;
        }
        if (n > PT_TEXT_MAX) {
            n = PT_TEXT_MAX;
        }
        /* TESetText(text, length, hTE) — TextEdit.h:1355. It replaces the
         * record's text and resets the selection; it does NOT draw. */
        TESetText((Ptr)p->textBuf, n, te);
        pt_te_redraw(te, w);
    }
    pt_te_read(p, te);
    p->error = PT_ERR_NONE;
    p->status = PT_STATUS_DONE;
}

/* Called from the GNEFilter shim on every GetNextEvent, in whatever process is
 * asking. Returns immediately unless a request names THIS A5 world. */
void pt_gne_serve(void)
{
    PTSharedPtr p = gPortal;
    unsigned long a5;

    if (p == NULL || p->magic != PT_MAGIC || !p->enabled) {
        return;                 /* bypassed: behave as though we are not here */
    }
    if (p->status != PT_STATUS_PENDING) {
        return;
    }
    a5 = LM_CURRENT_A5;
    if (p->targetA5 != (uint32_t)a5) {
        return;         /* not our turn; some other process will match */
    }

    p->seq++;                       /* odd: a reader must retry */
    p->servedA5 = (uint32_t)a5;
    p->servedTicks = (uint32_t)LM_TICKS;
    p->itemCount = 0;

    switch (p->op) {
    case PT_OP_MENU_GEOMETRY:
        pt_serve_menu_geometry(p);
        break;
    case PT_OP_SELFTEST: {
        /* Call MenuSelect ourselves, armed, and check we get back exactly what
         * the patch answered with. This runs the REAL calling convention — the
         * caller pushes a result slot, we answer, the callee pops — so a wrong
         * result offset or a missing pop shows up here as a mismatch instead of
         * as an application that mysteriously does nothing.
         *
         * Point (0,0) is outside the menu bar, so if the patch somehow does NOT
         * answer, the real MenuSelect returns 0 immediately without drawing or
         * tracking anything. Either way this is cheap and side-effect free. */
        Point p0;
        long  got;

        p->menuID = 999;              /* a menu that does not exist */
        p->itemIndex = 7;
        p->selftestWant = ((999UL & 0xFFFFUL) << 16) | 7UL;
        p->selftestGot = 0;
        p->fired = 0;
        p->armed = 1;

        p0.h = 0;
        p0.v = 0;
        got = MenuSelect(p0);
        p->selftestGot = (uint32_t)got;

        p->armed = 0;
        if (!p->fired) {
            p->error = PT_ERR_NOT_TAKEN;
            p->status = PT_STATUS_ERROR;
        } else if ((uint32_t)got != p->selftestWant) {
            p->error = PT_ERR_ABI;    /* answered, but the caller read junk */
            p->status = PT_STATUS_ERROR;
        } else {
            p->error = PT_ERR_NONE;
            p->status = PT_STATUS_DONE;
        }
        break;
    }
    case PT_OP_TEXT_GET:
        pt_serve_text(p, 0);
        break;
    case PT_OP_TEXT_SET:
        pt_serve_text(p, 1);
        break;
    case PT_OP_CONTROL_INVOKE:
        if (gOldTrackControl == NULL) {
            p->error = PT_ERR_NO_CTL_PATCH;
            p->status = PT_STATUS_ERROR;
            break;
        }
        p->fired = 0;
        p->armed = 1;
        p->status = PT_STATUS_DONE;
        break;
    case PT_OP_WINDOW_ACT:
        pt_serve_window_act(p);
        break;
    case PT_OP_MENU_INVOKE:
        /* Arming happens HERE, in the target's own context, rather than from
         * the host: it proves the target is alive and pumping before anything
         * is armed, and it means the patch is only ever live while the process
         * it names is actually running. The caller then posts the mouseDown
         * that makes the app call MenuSelect. */
        if (gOldMenuSelect == NULL) {
            p->error = PT_ERR_NO_PATCH;
            p->status = PT_STATUS_ERROR;
            break;
        }
        p->fired = 0;
        p->armed = 1;
        p->status = PT_STATUS_DONE;
        break;
    default:
        p->error = PT_ERR_BAD_OP;
        p->status = PT_STATUS_ERROR;
        break;
    }
    p->seq++;                       /* even: the reply is coherent */
}

/* ---- the MenuSelect patch ------------------------------------------------- */

/*
 * Called from the patch trampoline, inside whatever process just called
 * MenuSelect. Returns the packed (menuID<<16 | item) to answer with, or 0 to
 * mean "not ours" — in which case the trampoline chains to the real trap and the
 * user's click behaves exactly as it always did.
 *
 * The guard is deliberately strict, because a patch that fires when it should
 * not is indistinguishable from the machine going haywire: there must be an
 * armed invoke request, addressed to the A5 world we are running in right now.
 * It disarms itself on the way out, so one request answers exactly one call.
 */
long pt_menuselect_answer(long startPt);

/*
 * `startPt` is MenuSelect's own argument, passed down by the trampoline: a
 * Point packed as (v << 16) | h.
 *
 * It is here because of a measurement on 2026-07-31. This patch checked armed,
 * op and A5 and stopped, so it answered whichever MenuSelect arrived first —
 * and with a request armed, a real user's press on a DIFFERENT menu ran the
 * armed command 18 times out of 20. The TrackControl patch, which additionally
 * requires the request to name THAT ControlHandle, hijacked 0/20 under the same
 * test. The identity check is the guard; disarming after one use never was,
 * because it says the patch fires once and nothing about whose call it fires
 * on.
 *
 * A menu press carries no handle to check, so the identity is the press itself.
 * The verb synthesises the click, so it knows the exact point MenuSelect will
 * receive; a press anywhere else belongs to somebody else and chains through.
 * The tolerance is +/-2 pixels rather than zero because an application is free
 * to hand MenuSelect a point it has adjusted, and a guard that is wrong in the
 * strict direction breaks the legitimate request instead of the hijack.
 */
long pt_menuselect_answer(long startPt)
{
    PTSharedPtr p = gPortal;
    long        packed;
    short       h, v;

    /* The bypass is checked FIRST and cheapest: when the Portal is off this is
     * a load and a branch, and every MenuSelect in the system goes to the real
     * trap exactly as it would without us. */
    if (p == NULL || p->magic != PT_MAGIC || !p->enabled || !p->armed) {
        return 0;
    }
    if (p->op != PT_OP_MENU_INVOKE && p->op != PT_OP_SELFTEST) {
        return 0;
    }
    if (p->targetA5 != (uint32_t)LM_CURRENT_A5) {
        return 0;               /* someone else's menu click; leave it alone */
    }
    /* Is this OUR press? Negative means unguarded (selftest only). */
    if (p->op == PT_OP_MENU_INVOKE && p->armPointH >= 0) {
        h = (short)(startPt & 0xFFFF);
        v = (short)((startPt >> 16) & 0xFFFF);
        if (h < (short)(p->armPointH - 2) || h > (short)(p->armPointH + 2)
            || v < (short)(p->armPointV - 2) || v > (short)(p->armPointV + 2)) {
            return 0;           /* the user's own click; chain through */
        }
    }

    packed = ((long)(p->menuID & 0xFFFF) << 16) | (long)(p->itemIndex & 0xFFFF);

    p->armed = 0;               /* one request, one answer */
    p->fired = 1;
    p->servedTicks = (uint32_t)LM_TICKS;
    p->status = PT_STATUS_DONE;
    return packed;
}

/* ---- the TrackControl patch ------------------------------------------------ */

/* _TrackControl. Documented trap number (Inside Macintosh, the Control Manager). */
#define kTrackControlTrap 0xA968

/*
 * Answer the target's TrackControl with the part code the request names, so the
 * application runs its own mouse-down handler for that control. Returns 0 to
 * decline — which is also TrackControl's own "released outside the control", so
 * declining is indistinguishable from an ordinary miss.
 *
 * Guarded like the menu patch, plus one more condition: the request must name
 * THIS control. A patch that answered for whichever control happened to be
 * tracked would fire on the user's next scrollbar drag.
 */
short pt_trackcontrol_answer(void *whichControl, void *actionProc);

short pt_trackcontrol_answer(void *whichControl, void *actionProc)
{
    PTSharedPtr p = gPortal;
    PTActionProc action;

    if (p == NULL || p->magic != PT_MAGIC || !p->enabled || !p->armed) {
        return 0;
    }
    if (p->op != PT_OP_CONTROL_INVOKE) {
        return 0;
    }
    if (p->targetA5 != (uint32_t)LM_CURRENT_A5) {
        return 0;
    }
    if (p->controlHandle != (uint32_t)(unsigned long)whichControl) {
        return 0;               /* a different control; leave it alone */
    }

    p->armed = 0;
    p->fired = 1;
    p->servedTicks = (uint32_t)LM_TICKS;
    p->status = PT_STATUS_DONE;

    /* TrackControl has TWO halves, and only one of them is the return value.
     *
     * A push button does its work AFTER TrackControl returns, from the part
     * code — so answering is enough. A scroll bar does its work DURING
     * tracking, in the action procedure the app hands us, which the Control
     * Manager calls repeatedly while the button is held. Answering the return
     * value alone therefore drives buttons and does nothing at all to a
     * scroll bar.
     *
     * So call the action once, which is what a single click of tracking does.
     * Once, not repeatedly: a caller that wants to page twice can ask twice,
     * and a loop here would be a held button nobody asked for. The thumb
     * (part 129) has no action-proc semantics and is left alone.
     *
     * CORRECTION 2026-07-31. The comment here used to say this had been
     * measured and still left the scroll bar unmoved, and it named a next
     * hypothesis: that the action procedure consults live input (StillDown,
     * GetMouse) and no-ops because the injected click is already released. It
     * does not. Both halves work, at 20/20 each on mac99 with the control's own
     * value as the oracle. The unmoved scroll bar was the CALLER's part code:
     * `ctlinvoke`'s own documentation listed 10/11/12/13 for the four scroll
     * bar parts, and the real ones are 20/21/22/23. The action procedure was
     * being handed a part its scroll bar has no meaning for, and correctly did
     * nothing. Reproduced by mutation — part 12 gives a truthful `answered:true`
     * and 0/5 actuation, which is exactly the symptom that was reported.
     *
     * So a single, unheld action-proc call is sufficient for SimpleText's
     * scroll bar. Whether some other application's action procedure wants a
     * held button remains open — untested, not disproved. */
    p->sawActionProc = (uint32_t)(unsigned long)actionProc;
    action = (PTActionProc)actionProc;
    /* -1 is the Control Manager's documented sentinel for "use the control's
     * own action procedure", NOT a callable address. Calling it would jump to
     * 0xFFFFFFFF. */
    if ((unsigned long)actionProc == 0xFFFFFFFFUL) {
        action = NULL;
    }
    if (action != NULL && p->partCode != 129) {
        action((ControlHandle)whichControl, (short)p->partCode);
    }
    return (short)p->partCode;
}

/* ---- the window patches ---------------------------------------------------- */

/* Documented trap numbers, taken from the ONEWORDINLINE on each declaration in
 * `MacWindows.h` (Universal Interfaces 3.4) — not from a disassembly and not
 * from memory:
 *
 *      FindWindow    0xA92C   MacWindows.h:2986
 *      GrowWindow    0xA92B   MacWindows.h:4014
 *      TrackBox      0xA83B   MacWindows.h:4963
 *      TrackGoAway   0xA91E   MacWindows.h:4977
 *
 * TrackBox is in the 0xA8xx range and the other three in 0xA9xx; both are
 * ToolTrap, which is what NGetTrapAddress/NSetTrapAddress are told below. */
#define kFindWindowTrap  0xA92C
#define kGrowWindowTrap  0xA92B
#define kTrackBoxTrap    0xA83B
#define kTrackGoAwayTrap 0xA91E

/* The guard every window patch shares: an armed PT_OP_WINDOW_ACT request at the
 * given stage, in the A5 world we are running in right now, naming a window.
 * Written once so the four patches cannot drift apart — the arming discipline
 * is the thing a no-hijack measurement is measuring, and four hand-copies of it
 * is four chances to write a fifth one by accident. */
/* Count a trap entry against the request, if there is one for this process.
 * Separate from the guard so it runs even when the guard is about to decline —
 * "called and declined" and "never called" are opposite repairs. */
static void pt_window_hit(int index)
{
    PTSharedPtr p = gPortal;

    if (p == NULL || p->magic != PT_MAGIC) {
        return;
    }
    p->trapHits[index]++;
    if (p->op == PT_OP_WINDOW_ACT && p->armed != PT_ARM_NONE
        && p->targetA5 == (uint32_t)LM_CURRENT_A5) {
        p->trapHitsTarget[index]++;
    }
}

static PTSharedPtr pt_window_request(uint32_t stage)
{
    PTSharedPtr p = gPortal;

    if (p == NULL || p->magic != PT_MAGIC || !p->enabled) {
        return NULL;
    }
    if (p->armed != stage || p->op != PT_OP_WINDOW_ACT) {
        return NULL;
    }
    if (p->targetA5 != (uint32_t)LM_CURRENT_A5) {
        return NULL;
    }
    return p;
}

/*
 * Answer FindWindow with the part the request needs, and hand back the target
 * window through the caller's out parameter.
 *
 * `point` is the Point argument as its raw 32 bits. A Point is `{short v;
 * short h}` (Inside Macintosh: Imaging With QuickDraw), so v is the HIGH word.
 * The match against the point we posted is what keeps this from firing on a
 * user's own click: only the mouseDown this request queued has those exact
 * coordinates, because `post_click_at` stamps evtQWhere on the queue element
 * rather than leaving `where` to the live mouse.
 *
 * Returns 0 to decline. 0 is inDesk — a real FindWindow answer — so the shim
 * chains to the true trap rather than returning it.
 */
short pt_findwindow_answer(unsigned long point, void **outWindow);

short pt_findwindow_answer(unsigned long point, void **outWindow)
{
    /* Answer at EITHER stage, not only the first.
     *
     * Measured 2026-07-31 on mac99/SimpleText: one posted click produced TWO
     * FindWindow entries and zero TrackGoAway entries. A patch that answers
     * only the first hands the application our part code and then lets the
     * REAL FindWindow answer the second call with inContent — which is a
     * truthful answer to a click at the window's centre, and which sends the
     * application down its content branch instead of its close branch. So the
     * arm stays answerable until the second-stage trap consumes it.
     *
     * This does not widen the guard in any other direction: the point must
     * still be the exact one we posted, in the target's A5 world, for a window
     * request that is still armed. */
    PTSharedPtr p = pt_window_request(PT_ARM_READY);
    short       v;
    short       h;
    short       part;

    pt_window_hit(0);              /* entered, before any guard runs */
    if (p == NULL) {
        p = pt_window_request(PT_ARM_WINDOW_STAGE2);
    }
    if (p == NULL || outWindow == NULL) {
        return 0;
    }
    if (p->windowOp == PT_WIN_MOVE) {
        return 0;               /* MOVE never arms a patch; see the serve path */
    }
    v = (short)((point >> 16) & 0xFFFFUL);
    h = (short)(point & 0xFFFFUL);
    if (!(p->clickH == -1 && p->clickV == -1)
        && ((int32_t)h != p->clickH || (int32_t)v != p->clickV)) {
        return 0;               /* not the click we queued; leave it alone */
    }

    switch (p->windowOp) {
    case PT_WIN_RESIZE: part = PT_IN_GROW; break;
    case PT_WIN_ZOOM:   part = (short)p->zoomPart; break;
    case PT_WIN_CLOSE:  part = PT_IN_GO_AWAY; break;
    default:            return 0;
    }

    *outWindow = (void *)(unsigned long)p->windowPtr;
    p->findWindowFired = 1;
    p->fwAnswers++;
    p->armed = PT_ARM_WINDOW_STAGE2;   /* the second patch may now answer */
    p->servedTicks = (uint32_t)LM_TICKS;
    return part;
}

/*
 * Answer GrowWindow with the size the request names.
 *
 * The packing is documented (Inside Macintosh: Macintosh Toolbox Essentials,
 * the Window Manager): the high-order word of the result is the new HEIGHT and
 * the low-order word the new WIDTH, and 0 means "the size did not change". That
 * order is easy to get backwards and nothing in the headers states it, so it is
 * checked by measurement rather than asserted: `winact resize` asks for a
 * width and a height that differ, and re-reads the window's own rect. Swapped,
 * a 420x260 request comes back 260x420 and the trial fails loudly.
 *
 * The application then calls SizeWindow itself and adjusts its own content —
 * which is why this is a patch. A window resized behind the application's back
 * keeps its scroll bars where they were.
 */
long pt_growwindow_answer(void *window, unsigned long point);

long pt_growwindow_answer(void *window, unsigned long point)
{
    PTSharedPtr p = pt_window_request(PT_ARM_WINDOW_STAGE2);

    (void)point;                /* GrowWindow's start point is the app's, not
                                 * ours; the request already names the size */
    pt_window_hit(1);              /* entered, before any guard runs */
    if (p == NULL || p->windowOp != PT_WIN_RESIZE) {
        return 0;
    }
    if (p->windowPtr != (uint32_t)(unsigned long)window) {
        return 0;               /* a different window; leave it alone */
    }
    p->armed = PT_ARM_NONE;
    p->fired = 1;
    p->servedTicks = (uint32_t)LM_TICKS;
    return (long)(((unsigned long)(p->winV & 0xFFFF) << 16)
                  | ((unsigned long)p->winH & 0xFFFFUL));
}

/* Answer TrackBox true: the user clicked the zoom box and released inside it.
 * The application calls ZoomWindow with the same part code FindWindow just
 * handed it, and then adjusts its content. */
short pt_trackbox_answer(void *window, long part);

short pt_trackbox_answer(void *window, long part)
{
    PTSharedPtr p = pt_window_request(PT_ARM_WINDOW_STAGE2);

    pt_window_hit(2);              /* entered, before any guard runs */
    if (p == NULL || p->windowOp != PT_WIN_ZOOM) {
        return 0;
    }
    if (p->windowPtr != (uint32_t)(unsigned long)window) {
        return 0;
    }
    if (part != p->zoomPart) {
        /* The app is tracking a different box than the one we answered
         * FindWindow with. Declining is the honest move; the request stays at
         * stage 2 and the verb's timeout withdraws it. */
        return 0;
    }
    p->armed = PT_ARM_NONE;
    p->fired = 1;
    p->servedTicks = (uint32_t)LM_TICKS;
    return 1;
}

/*
 * Answer TrackGoAway true: the user clicked the close box and released inside
 * it. What happens next belongs to the application, and that is deliberate.
 *
 * This op can destroy a document. Closing a window by calling CloseWindow or
 * DisposeWindow from out here would do it with no prompt at all and leave the
 * application holding a pointer to a window that no longer exists. Answering
 * TrackGoAway instead runs the application's OWN close path — including its
 * save-changes dialog. So `winact close` does not promise the window closes; it
 * promises the application was asked to close it, exactly as a user clicking
 * the box would have asked. An unsaved document answers with a dialog, and the
 * window is still there. That is a correct outcome and the verb reports it as
 * one.
 */
short pt_trackgoaway_answer(void *window, unsigned long point);

short pt_trackgoaway_answer(void *window, unsigned long point)
{
    PTSharedPtr p = pt_window_request(PT_ARM_WINDOW_STAGE2);

    (void)point;

    pt_window_hit(3);              /* entered, before any guard runs */
    if (p == NULL || p->windowOp != PT_WIN_CLOSE) {
        return 0;
    }
    if (p->windowPtr != (uint32_t)(unsigned long)window) {
        return 0;
    }
    p->armed = PT_ARM_NONE;
    p->fired = 1;
    p->servedTicks = (uint32_t)LM_TICKS;
    return 1;
}

/* ---- Gestalt publisher ---------------------------------------------------- */

static pascal OSErr pt_gestalt(OSType selector, long *response)
{
#pragma unused(selector)
    *response = (long)gPortal;
    return noErr;
}

/* ---- install -------------------------------------------------------------- */

void _start(void)
{
    Handle              self;
    SelectorFunctionUPP gestaltUPP;
    OSErr               err;
    long                existing = 0;

    RETRO68_RELOCATE();
    Retro68CallConstructors();

    /* Refuse to install twice — a second copy in Extensions would otherwise
     * chain onto itself and publish a second block. */
    if (Gestalt(PT_GESTALT, &existing) == noErr && existing != 0) {
        return;
    }

    /* Stay resident: detach our own code resource so closing the extension file
     * does not dispose it. Loaded locked+sysHeap (Portal.r), so it will not move
     * and the relocation above stays valid. */
    self = Get1Resource('INIT', 128);
    if (self == NULL) {
        return;
    }
    DetachResource(self);

    /* System heap => addressable from every process, including the agent. */
    gPortal = (PTSharedPtr)NewPtrSysClear((Size)sizeof(PTShared));
    if (gPortal == NULL) {
        return;
    }
    gPortal->magic = PT_MAGIC;
    gPortal->version = PT_VERSION;
    gPortal->status = PT_STATUS_IDLE;
    /* Enabled at boot preserves today's behaviour on a disposable clone. Before
     * this goes near metal the default belongs at 0, so an installed Portal does
     * nothing until something deliberately turns it on — that is a one-constant
     * change, and it is the right one there. */
    gPortal->enabled = 1;

    gestaltUPP = NewSelectorFunctionUPP(pt_gestalt);
    if (gestaltUPP == NULL) {
        return;
    }
    err = NewGestalt(PT_GESTALT, gestaltUPP);
    if (err != noErr) {
        return;
    }

    /* On classic 68K a GetNextEventFilterUPP is a raw ProcPtr. The hook has a
     * special register ABI, so pt_gne_filter is an assembly shim rather than a
     * C callback; it tail-chains whatever filter was present. */
    /* Patch _MenuSelect. The trap table is system-wide, so the patch itself is
     * guarded (see pt_menuselect_answer): it acts only for an armed request in
     * the matching A5 world and chains through for everyone else. Installed
     * once, at boot, and never removed — a patch that could vanish while a
     * caller is inside it is worse than one that stays. */
    gOldMenuSelect = (void *)NGetTrapAddress(kMenuSelectTrap, ToolTrap);
    if (gOldMenuSelect != NULL) {
        NSetTrapAddress((UniversalProcPtr)pt_menuselect_patch,
                        kMenuSelectTrap, ToolTrap);
    }

    gOldTrackControl = (void *)NGetTrapAddress(kTrackControlTrap, ToolTrap);
    if (gOldTrackControl != NULL) {
        NSetTrapAddress((UniversalProcPtr)pt_trackcontrol_patch,
                        kTrackControlTrap, ToolTrap);
    }

    /* The four window traps. Same discipline: guarded, installed once at boot,
     * never removed. Each is installed only if its original could be read, and
     * the serve path refuses the sub-op whose patch is missing rather than
     * arming something that can never fire. */
    gOldFindWindow = (void *)NGetTrapAddress(kFindWindowTrap, ToolTrap);
    if (gOldFindWindow != NULL) {
        NSetTrapAddress((UniversalProcPtr)pt_findwindow_patch,
                        kFindWindowTrap, ToolTrap);
    }
    gOldGrowWindow = (void *)NGetTrapAddress(kGrowWindowTrap, ToolTrap);
    if (gOldGrowWindow != NULL) {
        NSetTrapAddress((UniversalProcPtr)pt_growwindow_patch,
                        kGrowWindowTrap, ToolTrap);
    }
    gOldTrackBox = (void *)NGetTrapAddress(kTrackBoxTrap, ToolTrap);
    if (gOldTrackBox != NULL) {
        NSetTrapAddress((UniversalProcPtr)pt_trackbox_patch,
                        kTrackBoxTrap, ToolTrap);
    }
    gOldTrackGoAway = (void *)NGetTrapAddress(kTrackGoAwayTrap, ToolTrap);
    if (gOldTrackGoAway != NULL) {
        NSetTrapAddress((UniversalProcPtr)pt_trackgoaway_patch,
                        kTrackGoAwayTrap, ToolTrap);
    }

    gOldGNEFilter = LMGetGNEFilter();
    LMSetGNEFilter((GetNextEventFilterUPP)pt_gne_filter);

    /* Intentionally NOT calling Retro68FreeGlobals(): the block, the old-filter
     * pointer and the shim must stay resident for the machine's lifetime. */
}
