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

#include <Retro68Runtime.h>

#include <Gestalt.h>
#include <MacMemory.h>
#include <Menus.h>
#include <Controls.h>
#include <Quickdraw.h>
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

extern void pt_gne_filter(void);
extern void pt_menuselect_patch(void);
extern void pt_trackcontrol_patch(void);

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
long pt_menuselect_answer(void);

long pt_menuselect_answer(void)
{
    PTSharedPtr p = gPortal;
    long        packed;

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
     * scrollbar: measured, `answered:true` with the value unmoved.
     *
     * So call the action once, which is what a single click of tracking does.
     * Once, not repeatedly: a caller that wants to page twice can ask twice,
     * and a loop here would be a held button nobody asked for. The thumb
     * (part 129) has no action-proc semantics and is left alone. */
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

    gOldGNEFilter = LMGetGNEFilter();
    LMSetGNEFilter((GetNextEventFilterUPP)pt_gne_filter);

    /* Intentionally NOT calling Retro68FreeGlobals(): the block, the old-filter
     * pointer and the shim must stay resident for the machine's lifetime. */
}
