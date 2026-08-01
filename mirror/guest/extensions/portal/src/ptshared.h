/*
 * ptshared.h - the Portal shared-block contract.
 *
 * AXPeek proved the mechanism and used half of it. A GNEFilter INIT runs inside
 * EVERY application's context, with that process's A5 world current — which is
 * the only reason the per-process Toolbox roots are visible at all. AXPeek looks
 * through that window. The Portal reaches through it.
 *
 * The difference matters because everything the act plane cannot do from outside
 * is trivial from inside: per-process low memory is just memory, the Menu
 * Manager's own MDEF can be asked where its items are, and a tracking loop is
 * not something to defeat because we are already running underneath it.
 *
 * Shape, deliberately the same as AXPeek's so the discipline carries over: one
 * NewPtrSys block in the SYSTEM heap (globally addressable from any process),
 * its address published via Gestalt, coherence by seqlock. The host writes a
 * request addressed to a target A5; the hook executes it the next time it finds
 * itself running as that process, and writes the reply back.
 *
 * Addressing is by A5 rather than PSN on purpose: inside the hook, the current
 * A5 world is a single low-memory read (0x0904), while a PSN would need
 * Process Manager calls that are not safe there. The caller already knows the
 * mapping — AXPeek publishes A5 per process, which is exactly what its oracle
 * is for.
 *
 * Provenance: P-DOC. Low-memory addresses and the MDEF message protocol come
 * from Inside Macintosh (Toolbox Essentials, the Menu Manager); nothing here is
 * derived from a disassembly.
 */
#ifndef PORTAL_PTSHARED_H
#define PORTAL_PTSHARED_H

#include <stdint.h>

/* 'TBpt' — block magic and the Gestalt selector that publishes its address. */
#define PT_MAGIC    0x54427074UL
#define PT_GESTALT  0x54427074UL
/* 2 (2026-07-31): armPointH/armPointV added, and the MenuSelect guard now
 * requires the press to be the one we posted. A host built against version 1
 * would arm without a point and be hijack-prone, so the verb refuses a version
 * it does not know rather than writing fields the resident INIT has no room
 * for — a stale INIT is now a loud refusal instead of silent corruption. */
/* 3 (2026-07-31, lane P1): PT_OP_WINDOW_ACT's request and reply fields, all
 * appended after the version-2 layout. Same reasoning as version 2 — a host
 * built against 2 would write windowPtr/windowOp into a resident INIT that has
 * no room for them, which is silent corruption of the block rather than an
 * error, so a verb refuses a version it does not know. */
/* 4 (2026-07-31, lane P2 merged): the text ops appended textKind..textBuf,
 * after version 3's window fields. P2 developed against version 2 and called
 * its own layout 3; P1 landed first and 3 was taken, so the merged layout —
 * which is the only one that has BOTH sets of fields — takes the next number.
 * Two struct layouts both calling themselves 3 is exactly what this field
 * exists to prevent, so the merge renumbers rather than reconciling.
 *
 * It bites harder for the text ops than for the window ones: a version-3 INIT
 * allocated a SHORTER block, so an agent that wrote textBuf into it would
 * write past the end of a system-heap pointer. `textget`/`textset` refuse a
 * version below 4; `winact` still refuses below 3, since a version-3 INIT does
 * have every field it touches. */
#define PT_VERSION  4UL

#define PT_MAX_ITEMS 64        /* items reported per menu; fixed, never allocates */

/* Requests. A request is claimed by exactly one process — the one whose A5
 * matches — and the hook never blocks: if the target is not current, it does
 * nothing and the next process's hook call looks again. */
enum {
    PT_OP_NONE = 0,
    /* Ask the target's own Menu Manager where a menu's items ARE, rather than
     * assuming uniform rows. This is the whole reason menu selection missed:
     * the guest reports no item geometry, and separators are not row-height. */
    PT_OP_MENU_GEOMETRY = 1,
    /* Perform a menu command the way the application itself would: arm a
     * guarded MenuSelect patch so the app's own call returns our chosen
     * (menuID, item) and its own command handler runs. No menu is drawn, no
     * tracking loop runs, and nothing depends on mouse motion or timing. */
    PT_OP_MENU_INVOKE = 2,
    /* Prove the patch's calling convention against a known answer, in the
     * target's own context. The ABI bug this exists to catch was SILENT: the
     * patch reported firing and the application did nothing, because the value
     * it read was never the value we wrote. A wrong ABI does not crash, it
     * lies — so the mechanism has to be able to check itself. */
    PT_OP_SELFTEST = 3,
    /* Act on a control the way the application would: arm a guarded
     * TrackControl patch so the app's own call returns the part code we choose.
     * The app then runs its real mouse-down handler. Same shape as
     * MENU_INVOKE — answer the question the app asks, rather than simulating a
     * user convincingly enough to make it ask. */
    PT_OP_CONTROL_INVOKE = 4,
    /* Move, resize, zoom or close a window without simulating a drag. This is
     * the op that removes QMP from the act plane: a coordinate drag needs
     * injected mouse MOTION, which only exists on the emulator, while every
     * mechanism here is an in-guest Toolbox call the application itself would
     * have made. See PT_WIN_* for the four sub-ops and how each is served. */
    PT_OP_WINDOW_ACT = 5,
    /* Read a text field's real contents, in the application's own context.
     * From outside, a TextEdit record and a dialog's item list are per-process
     * roots the walk cannot dereference; from in here they are just memory the
     * Toolbox will hand us on request.
     *
     * 6, not 5: lane P2 developed this as op 5 against a tree where 5 was free,
     * and PT_OP_WINDOW_ACT took 5 first. Renumbered on the P2 side at merge
     * because WINDOW_ACT was already deployed. */
    PT_OP_TEXT_GET = 6,
    /* Write them. Unlike GET this changes the document, so it carries the
     * redraw obligation with it: TESetText does NOT display (Inside Macintosh:
     * Text, TextEdit), and a field that shows stale text is the screen lying
     * about the document. */
    PT_OP_TEXT_SET = 7
};

/* PT_OP_WINDOW_ACT sub-ops, in `windowOp`.
 *
 * Three of the four are served the way MENU_INVOKE and CONTROL_INVOKE are: arm
 * a guarded trap patch, post a click, and answer the question the app asks so
 * the app runs its own code. MOVE is the exception and the reason is in the
 * Toolbox's own signature — `DragWindow` returns void, so there is no answer to
 * give; it performs the move itself. Nothing is asked, so nothing can be
 * answered, and the honest equivalent is to make the same Window Manager call
 * DragWindow would have made, in the target's own context. */
enum {
    /* MoveWindow(w, winH, winV, false), called directly in the target's
     * context from the GNEFilter hook. No patch, no click. */
    PT_WIN_MOVE = 1,
    /* FindWindow -> inGrow (5), then GrowWindow -> (winV<<16 | winH). The app
     * calls SizeWindow itself and then adjusts its own content — which is why
     * this is a patch rather than a direct SizeWindow: a window resized behind
     * the application's back keeps its scroll bars where they were. */
    PT_WIN_RESIZE = 2,
    /* FindWindow -> zoomPart (inZoomIn 7 / inZoomOut 8), then TrackBox -> true.
     * The app calls ZoomWindow itself, same reasoning as RESIZE. */
    PT_WIN_ZOOM = 3,
    /* FindWindow -> inGoAway (6), then TrackGoAway -> true. The app runs ITS
     * OWN close path from there, which is the entire point: closing a window
     * by calling CloseWindow ourselves would tear down a document behind the
     * application's back and skip the save-changes prompt. See the `winact`
     * verb's contract in mirrorverbs.c — this op can present a dialog and
     * leave the window open, and that is a correct outcome, not a failure. */
    PT_WIN_CLOSE = 4
};

/* FindWindow part codes (Inside Macintosh: Macintosh Toolbox Essentials, the
 * Window Manager; `MacWindows.h`, WindowPartCode). Named here rather than
 * spelled inline because there is a SECOND, similarly-named set — the WDEF
 * message part codes wInContent=1, wInDrag=2, wInGrow=3, wInGoAway=4,
 * wInZoomIn=5, wInZoomOut=6 — and confusing the two is precisely the shape of
 * the phantom-constant bug that cost CONTROL_INVOKE a day. These are the
 * FindWindow values, verified against `MacWindows.h:445-456`. */
enum {
    PT_IN_DESK = 0,
    PT_IN_MENU_BAR = 1,
    PT_IN_SYS_WINDOW = 2,
    PT_IN_CONTENT = 3,
    PT_IN_DRAG = 4,
    PT_IN_GROW = 5,
    PT_IN_GO_AWAY = 6,
    PT_IN_ZOOM_IN = 7,
    PT_IN_ZOOM_OUT = 8
};

/* `armed` is a STAGE for PT_OP_WINDOW_ACT, not a flag, because two patches have
 * to fire in order for one request. FindWindow may only answer at stage 1 and
 * leaves stage 2 behind it; the second patch may only answer at stage 2. So the
 * second patch can never fire without FindWindow having fired first for this
 * same request — a stricter guard than a single flag, not a looser one. Both
 * clear to 0 on the way out, exactly as MENU_INVOKE and CONTROL_INVOKE do. */
enum {
    PT_ARM_NONE = 0,
    PT_ARM_READY = 1,           /* menu/control: fire. window: FindWindow may  */
    PT_ARM_WINDOW_STAGE2 = 2    /* window: Grow/TrackBox/TrackGoAway may fire  */
};

/* How the request names the text. Both kinds require `textWindow`, and the
 * window must be in THIS process's window list — that is the identity check,
 * and it is the guard. "Something is armed in this process" is not one; see
 * PORTAL-PLAN.md, the MENU_INVOKE leak measured 2026-07-31. */
enum {
    /* A dialog item by 1-based number, through GetDialogItem /
     * GetDialogItemText / SetDialogItemText (Inside Macintosh: Toolbox
     * Essentials, the Dialog Manager). */
    PT_TEXT_KIND_DITEM = 1,
    /* A TEHandle named explicitly. Validated BOTH ways: the window must be
     * ours, and the TERec's own `inPort` must be that window's port
     * (TERec.inPort, TextEdit.h). A handle from another process therefore
     * cannot be written through, because its inPort names none of our
     * windows. */
    PT_TEXT_KIND_TE = 2,
    /* The dialog's own live TextEdit record — DialogRecord.textH (Dialogs.h),
     * the record the Dialog Manager gives every editText item. This is the
     * discoverable route to a real TEHandle: the caller names only the window,
     * and the reply carries the handle it used. */
    PT_TEXT_KIND_DIALOG_TE = 3
};

/* Text carried in a request or a reply. Str255-shaped because a dialog item's
 * text is a Str255 at the Dialog Manager boundary (GetDialogItemText takes a
 * Str255), so 255 is the honest ceiling for the DITEM kind and the same buffer
 * serves TE. A longer TE record is reported truncated, with its true length in
 * `textLength`, rather than silently clipped. */
#define PT_TEXT_MAX 255

/* Request status, written by the hook. */
enum {
    PT_STATUS_IDLE = 0,
    PT_STATUS_PENDING = 1,      /* posted by the host, not yet claimed        */
    PT_STATUS_DONE = 2,
    PT_STATUS_ERROR = 3
};

/* Error codes; small and specific, so a failure names itself. */
enum {
    PT_ERR_NONE = 0,
    PT_ERR_NO_MENU = 1,         /* no such menu id in this process's MenuList */
    PT_ERR_NO_MDEF = 2,         /* the menu's MDEF handle was not loadable    */
    PT_ERR_BAD_OP = 3,
    PT_ERR_NO_PATCH = 4,        /* the MenuSelect patch was never installed  */
    PT_ERR_NOT_TAKEN = 5,       /* armed, but the app never called MenuSelect */
    PT_ERR_NO_CTL_PATCH = 7,    /* the TrackControl patch was never installed */
    PT_ERR_ABI = 6,             /* the patch answered, and the caller read
                                 * something else — the Pascal result slot or
                                 * the callee-pops contract is wrong */
    /* --- window act (op 5). Appended by lane P1; existing codes unmoved. --- */
    PT_ERR_NO_WIN_PATCH = 8,    /* a window patch was never installed         */
    PT_ERR_BAD_WINDOW_OP = 9,   /* windowOp is not a PT_WIN_* value           */
    PT_ERR_NO_WINDOW = 10,      /* windowPtr is zero                          */
    /* --- text ops (6, 7). Appended by lane P2; existing codes unmoved.
     * P2 authored these as 8..13 against a tree where 8 was free, and the
     * window codes took 8..10 first, so the merge renumbers the P2 side. Its
     * first code was also named PT_ERR_NO_WINDOW — same name, a DIFFERENT
     * condition (window not ours, versus windowPtr zero) — so it is renamed
     * rather than folded into 10. Collapsing two distinct failures onto one
     * code is how a specific error stops naming itself. */
    PT_ERR_TEXT_NO_WINDOW = 11, /* the named window is not in THIS process's
                                 * window list — the identity check failing,
                                 * which is the case that must never write   */
    PT_ERR_NOT_DIALOG = 12,     /* windowKind != dialogKind, so it has no
                                 * item list to index                        */
    PT_ERR_NO_ITEM = 13,        /* item number outside 1..CountDITL          */
    PT_ERR_BAD_TE = 14,         /* the TEHandle is NULL, purged, or its
                                 * inPort is not the window named            */
    PT_ERR_TEXT_KIND = 15,      /* unknown textKind                          */
    PT_ERR_NOT_TEXT = 16        /* the dialog item holds no text (not
                                 * editText or statText)                     */
};

typedef struct {
    int16_t top;
    int16_t left;
    int16_t bottom;
    int16_t right;
} PTRect;

typedef struct {
    uint32_t seq;               /* seqlock: odd while the hook is writing     */
    uint32_t magic;             /* PT_MAGIC once the INIT is live             */
    uint32_t version;

    /* --- the bypass switch ------------------------------------------------ *
     * Zero means the Portal does NOTHING: the GNEFilter hook returns before it
     * looks at anything, and the MenuSelect patch chains straight to the real
     * trap. The extension stays installed and the hook stays chained — we do
     * not unpatch, because a patch that vanishes while a caller is inside it is
     * worse than one that stays — but with this clear the machine behaves as
     * though the Portal were not there.
     *
     * It lives in the shared block rather than behind an op ON PURPOSE: the
     * host writes it directly, so turning the Portal OFF is immediate and does
     * not depend on the target process being alive, frontmost, or pumping its
     * event loop. A safety switch that needs the thing it is protecting you
     * from to cooperate is not a safety switch. */
    uint32_t enabled;

    /* --- request, written by the host ------------------------------------- */
    uint32_t targetA5;          /* which process this is addressed to         */
    uint32_t op;
    int32_t  menuID;            /* which menu (geometry, and invoke)          */
    int32_t  itemIndex;         /* PT_OP_MENU_INVOKE: 1-based item            */
    uint32_t controlHandle;     /* PT_OP_CONTROL_INVOKE: the ControlHandle    */
    int32_t  partCode;          /* PT_OP_CONTROL_INVOKE: part to answer with  */
    uint32_t status;
    uint32_t error;

    /* --- PT_OP_WINDOW_ACT request fields ----------------------------------- *
     * Appended rather than interleaved so the block's existing layout does not
     * move; the extension and the agent are built from this one header, but a
     * mismatched pair is a silent memory bug and appending makes it a smaller
     * class of one. */
    uint32_t windowPtr;         /* the target WindowPtr (a WindowPeek address) */
    int32_t  windowOp;          /* PT_WIN_*                                    */
    int32_t  winH;              /* MOVE: new global left. RESIZE: new width    */
    int32_t  winV;              /* MOVE: new global top.  RESIZE: new height   */
    int32_t  zoomPart;          /* ZOOM: PT_IN_ZOOM_IN or PT_IN_ZOOM_OUT       */
    /* The exact point the caller posted its click at. The FindWindow patch
     * answers ONLY for a Point equal to this one, which shrinks the hijack
     * window from "any mouseDown in the target app while armed" to "the one
     * event we ourselves queued". -1/-1 means match any point, and exists as a
     * diagnostic lever rather than a mode the verb ships in. */
    int32_t  clickH;
    int32_t  clickV;

    /* --- reply, written by the hook in the target's context ---------------- */
    uint32_t servedA5;          /* the A5 that actually served it             */
    uint32_t servedTicks;
    int32_t  itemCount;
    uint32_t armed;             /* invoke: the patch is waiting to fire       */
    uint32_t fired;             /* invoke: the patch answered a MenuSelect    */
    uint32_t sawActionProc;     /* control: the actionProc the app passed —
                                 * 0 = none, 0xFFFFFFFF = the Control Manager's
                                 * "use the control's own" sentinel, else a
                                 * real ProcPtr. Recorded because which of the
                                 * three it is decides how a control is driven */
    /* --- the MENU_INVOKE identity check -----------------------------------
     * Measured 2026-07-31: with a request armed, a real user's press on a
     * DIFFERENT menu ran the armed command 18/20. The menu patch checked armed
     * + op + A5 and stopped, so it answered whichever MenuSelect arrived first
     * — ours or the user's. The control patch, which additionally requires the
     * request to name THAT ControlHandle, hijacked 0/20 under the same test.
     *
     * The identity check is the guard; self-disarming never was. It says the
     * patch fires once, not WHOSE call it fires on.
     *
     * A menu press carries no handle to name, so the identity we check is the
     * click itself: the verb synthesises the press, so it knows the exact point
     * MenuSelect will receive, and a press anywhere else is somebody else's.
     * Negative means unguarded, which only PT_OP_SELFTEST uses (it rides no
     * user click at all). */
    int32_t  armPointH;
    int32_t  armPointV;

    uint32_t selftestWant;      /* selftest: the packed value we answered with */
    uint32_t selftestGot;       /* selftest: what the caller actually received */
    /* window: FindWindow answered and handed the app its part code. Recorded
     * separately from `fired` because the two failures are different repairs:
     * findWindowFired=0 means the click never reached the app's FindWindow,
     * and findWindowFired=1 with fired=0 means the app took our part code and
     * declined to call the trap that goes with it. */
    uint32_t findWindowFired;
    /* Unconditional entry counters, one per window trap, bumped at the TOP of
     * each answer function before any guard runs. They answer the one question
     * a guarded patch cannot answer about itself: when nothing happens, was the
     * trap never called, or was it called and declined? Without them the two
     * are the same symptom, and guessing between them is how a day goes.
     * 0 FindWindow, 1 GrowWindow, 2 TrackBox, 3 TrackGoAway. */
    uint32_t trapHits[4];
    /* The same four counts, but scoped to the request: bumped only when the
     * current A5 is the target's AND a window request is armed. The global
     * counters above cannot tell our own click apart from any other process's,
     * which makes them ambiguous exactly where it matters. */
    uint32_t trapHitsTarget[4];
    /* How many times FindWindow answered for THIS request. More than one is
     * the finding, not a fault: it means the application asks twice per
     * mouseDown, and a patch that answers only the first hands the app our
     * part code and then lets the real trap overrule it with inContent. */
    uint32_t fwAnswers;
    int16_t  menuHeight;
    int16_t  menuWidth;
    PTRect   items[PT_MAX_ITEMS];   /* menu-local rects, item 1 at index 0    */

    /* --- text ops (PT_OP_TEXT_GET / PT_OP_TEXT_SET) ------------------------
     * Appended 2026-07-31 at the END of the record on purpose, after version
     * 3's window fields. Both sides now compile this one header, so they cannot
     * disagree at build time — but the INIT is RESIDENT, so a running version-3
     * INIT and a freshly built agent still disagree about every offset after an
     * inserted field. Appending keeps that failure to "the new fields are
     * absent", which the version check catches. */
    uint32_t textKind;          /* request: PT_TEXT_KIND_*                    */
    uint32_t textWindow;        /* request: the WindowPtr / DialogPtr named   */
    uint32_t textHandle;        /* request: PT_TEXT_KIND_TE, the TEHandle     */
    int32_t  textItem;          /* request: PT_TEXT_KIND_DITEM, 1-based item  */
    int32_t  textLength;        /* SET request: bytes in textBuf.
                                 * Either op's reply: the object's TRUE length
                                 * after the operation, which may exceed
                                 * textBufLength when a TE record is longer
                                 * than the buffer                           */
    int32_t  textBufLength;     /* reply: bytes actually placed in textBuf    */
    int32_t  textItemType;      /* reply: the dialog item's type byte
                                 * (editText 16, statText 8; Dialogs.h)      */
    uint32_t textTE;            /* reply: the TEHandle actually used, 0 if
                                 * the op went through the Dialog Manager    */
    uint8_t  textBuf[PT_TEXT_MAX + 1];
} PTShared;

typedef PTShared *PTSharedPtr;

#endif /* PORTAL_PTSHARED_H */
