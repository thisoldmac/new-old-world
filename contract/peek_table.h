#ifndef NOW_PEEK_TABLE_H
#define NOW_PEEK_TABLE_H

/* The NOW Extension's shared table - the in-memory contract between
   the 68K extension and the PPC application.
   ------------------------------------------------------------------
   This header is compiled by THREE compilers: the Retro68 68K build of
   the extension, the retrocarbon PPC build of the application, and the
   host cc for now-guest-ppc/tests/peek_table_test.c. It is the analogue of
   asyncapi.yaml for the in-memory seam (docs/resident-components.md),
   and the same rule applies: every limit is stated here, once.

   Layout rules that keep three compilers honest (m68k gcc aligns
   32-bit fields to 2 bytes, PPC to 4 - the silent-drift trap):
     - every field is 32 bits, or 16-bit fields come in adjacent pairs,
       so every offset is naturally 4-aligned and NO compiler inserts
       padding;
     - the static asserts below pin every offset; a layout change that
       breaks them does not build anywhere.

   Discovery: the extension registers Gestalt selector 'NWex' at INIT
   time; the response is the table's address in the system heap. The
   application requires magic and an exact ext_major, and gates every
   read on length (accretive, the prefs-record rule) plus the owning
   plane's format word. Capabilities are bits, never inferred from
   versions - a plane can ship dark before it is metal-verified.

   Write discipline: the extension's filter writes every field except
   arm_request, which only the application writes. One writer per word,
   both sides big-endian (same machine), no locks; stamp fields are the
   ordering signal - a reader treats a slot as valid only when its
   stamp is nonzero and fresh enough for the reader's purpose.
   Freshness is per-slot and honest: anchors are captured when a
   process pumps its event loop, so a faceless or wedged app has an
   absent or stale slot - distinct states, both rendered truthfully. */

#ifdef NOW_PEEK_TABLE_HOST
#include <stdint.h>
typedef uint16_t NowPeekU16;
typedef uint32_t NowPeekU32;
typedef int32_t NowPeekI32;
#else
#include <MacTypes.h>
typedef UInt16 NowPeekU16;
typedef UInt32 NowPeekU32;
typedef SInt32 NowPeekI32;
#endif

#include <stddef.h>

/* Spelled out so no compiler warns about multi-character constants. */
#define NOW_PEEK_4CC(a, b, c, d)                                      \
    (((NowPeekU32)(a) << 24) | ((NowPeekU32)(b) << 16)                \
     | ((NowPeekU32)(c) << 8) | (NowPeekU32)(d))

enum {
    /* Gestalt selector 'NWex'; response is the table address. */
    kNowPeekGestaltSelector = (long)NOW_PEEK_4CC('N', 'W', 'e', 'x'),
    /* First prelude field; a table without it is not a table. */
    kNowPeekTableMagic = (long)NOW_PEEK_4CC('N', 'W', 'p', 't'),

    /* Exact-match compatibility. Bump ONLY when an existing field's
       meaning changes; new fields ride on length instead. */
    kNowPeekExtMajor = 1,

    /* Matches the Process Manager walk's cap in processes_module.c;
       classic systems run a dozen-odd processes, 32 is headroom. */
    kNowPeekMaxAnchors = 32,

    kNowPeekAnchorFormatNone = 0, /* plane P1 absent (core-only M0) */
    kNowPeekAnchorFormatV1 = 1,   /* a5, window_list, menu_list */
    kNowPeekAnchorFormatV2 = 2,   /* + stack_base */
    kNowPeekAnchorFormatV3 = 3,   /* + cur_ap_name */

    /* Low memory's CurApName is a Str31 - one length byte plus up to 31
       characters - so 32 bytes holds it whole, with no truncation rule
       to get wrong on either side of the seam. 32 is also the only
       width that costs nothing: it is a multiple of 4, so the field
       after it stays naturally aligned and no compiler has to insert
       padding to reach it. A shorter field (say 28) would have to
       define what happens to a longer name, and every such definition
       is a way for two sides to disagree about identity - which is the
       one thing this field exists to settle. */
    kNowPeekAnchorNameSize = 32
};

enum {
    kNowPeekIdentityFormatNone = 0,
    kNowPeekIdentityFormatV1 = 1,
    kNowPeekIdentityWordCount = 5,
    kNowPeekWriterFormatNone = 0,
    kNowPeekWriterFormatV1 = 1,
    kNowPeekWriterLeaseTicks = 180,
    kNowPeekAnchorCadenceTicks = 6,
    kNowPeekCanonicalAppCreator =
        (long)NOW_PEEK_4CC('N', 'O', 'W', 'o'),
    /* A value, not a hash: only an app which has already compared its
       process name with "New Old World" publishes this token. */
    kNowPeekCanonicalAppName =
        (long)NOW_PEEK_4CC('N', 'W', 'c', 'n')
};

/* Plane capability bits (caps, arm_request, arm_active). The guest's
   peek.h aliases these - state them once, here. */
enum {
    kNowPeekTableCapAnchors = 1u << 0,  /* P1: per-process anchors */
    kNowPeekTableCapTree = 1u << 1,     /* P2: semantic-tree assist */
    kNowPeekTableCapAct = 1u << 2,      /* P4: the act plane (below) */
    kNowPeekTableCapContent = 1u << 3   /* P3: the content plane */
};

/* P3 asked for 1u << 2 and for its field at the head of the appended
   region; P4 had already taken both. Two lanes built against this header
   while it was held by a third, so each picked the next free bit and the
   next free offset from the version it could see - and a bit collision
   is silent in the worst possible way: an application arming P3 would
   have armed P4's six trap patches instead, in someone else's process.
   Recorded rather than tidied away, because the near miss is the reason
   this file states its bits and offsets in one place. Landed 2026-07-31.

   Declaring the macro is what retires content_table.h's shim: that
   header defined the bit itself while waiting, and defined it to the
   value P4 holds. */
#define NOW_PEEK_TABLE_HAS_CAP_CONTENT 1

/* ======================================================================
   P4 - THE ACT PLANE
   ======================================================================

   Every plane above this one READS. This one lets the application ask a
   foreign process to do something, and it is the only reason a semantic
   scene is worth more than a screenshot: the structure earns its cost
   when you can address an ELEMENT instead of a coordinate.

   Ported from the sibling Mirror project's Portal INIT
   (/Users/michelle/Lab/Code/timbottu/mirror, parked and complete), whose
   mechanism is metal-proven upstream and whose findings are carried here
   intact. Upstream's numbers, since they decide the shape below and not
   one of them was cheap: WINDOW_ACT 20/20 on each of four ops;
   TEXT_GET / TEXT_SET 20/20 with no-hijack 0/20; MENU_INVOKE's hijack
   closed 18/20 -> 0/19. NOTHING here inherits that measurement - the
   same mechanism in different surrounding code is strong evidence, not a
   result - and no claim on this side may say otherwise until a NOW
   machine has been watched.

   HOW IT WORKS. A request names a target A5 world. The core's jGNE
   filter is already running inside every process that pumps events, so
   the next time it finds itself running AS that process it serves the
   request in that context - which is the only place the process's own
   Window/Menu/Dialog roots exist at all (finding observe-process-local-
   ui). Two shapes:

     - The text ops are served OUTRIGHT in the hook. A TERec and a
       dialog's item list are not things the application is about to ask
       us about; they are per-process memory, and from inside they are
       simply readable and writable.
     - The menu, control and window ops ARM a guarded trap patch, and the
       application's OWN call to MenuSelect / TrackControl / FindWindow
       is answered with the value the request names. The application then
       runs its own handler. Nothing simulates a user; no mouse MOTION is
       injected anywhere, which is what keeps this plane off the emulator
       and inside the no-host-side-cheating rule.

   IDENTITY IS THE GUARD, and this is the single most expensive thing
   upstream learned. Disarming after one use is NOT a guard: it says the
   patch fires once and says nothing about WHOSE call it fires on. An
   armed menu request rode a real user's press on a different menu 18
   times in 20. The control patch, which additionally required the
   request to name that exact ControlHandle, hijacked 0 in 20. So every
   op below names its target and the patch refuses anything else:

     control  the ControlHandle the request names
     window   the WindowPtr the request names, plus the exact click point
     menu     the press ITSELF - a menu press carries no handle, so the
              identity checked is the point, which the caller knows
              because the caller synthesised the press. Tolerance is
              +/-2 px, erring loose on purpose: a guard wrong in the
              strict direction breaks the legitimate request instead of
              the hijack.
     text     the named window must be in the SERVING process's own
              window list - a claim "a request is pending in this
              process" does not make.

   A STALE RESIDENT IS AN UNGUARDED PATCH. An older extension has no room
   for these fields, so an application that wrote a request into it would
   corrupt the system-heap block AND believe a guard was on that is not
   there. NOW refuses that with the discipline it already has rather than
   with a second version number: `act_format` is this plane's own format
   word and `length` must cover the cell. A reader gates on BOTH and
   refuses otherwise - never on a nonzero value, never on ext_major
   alone. now_act_table_ready() (now_act_guard.h) is that gate, stated
   once.

   Provenance: P-DOC throughout. Trap numbers come from the ONEWORDINLINE
   on each declaration in Universal Interfaces 3.4; part codes from
   MacWindows.h; the Dialog/TextEdit record fields from Dialogs.h and
   TextEdit.h. Nothing here is derived from a disassembly. */

enum {
    kNowPeekActFormatNone = 0,  /* plane P4 absent */
    kNowPeekActFormatV1 = 1,    /* the original cell below, exactly */
    /* V1 stays byte-for-byte in place. V2 is its continuation at the
       tail of NowPeekTable, so adding identity cannot move P3 or U2/U3. */
    kNowPeekActFormatV2 = 2
};

/* Resident evidence only moves forward for one correlation. It is not the
   application settlement outcome: requested/armed/fired prove mechanism,
   never the guest-visible effect. Expired and refused are terminal resident
   evidence, while the application may still retain a timed-out correlation
   and later confirm its effect from a newer scene. */
enum {
    kNowPeekActStageNone = 0,
    kNowPeekActStageRequested = 1,
    kNowPeekActStageAccepted = 2,
    kNowPeekActStageArmed = 3,
    kNowPeekActStageFired = 4,
    kNowPeekActStageRefused = 5,
    kNowPeekActStageExpired = 6
};

/* Typed operation families for identity and settlement. Existing P4 op codes
   remain unchanged; this vocabulary distinguishes controls that happen to
   share a Toolbox mechanism but have different observable postconditions. */
enum {
    kNowPeekActKindNone = 0,
    kNowPeekActKindPopup = 1,
    kNowPeekActKindDialogItem = 2,
    kNowPeekActKindList = 3,
    kNowPeekActKindText = 4,
    kNowPeekActKindControl = 5,
    kNowPeekActKindMenu = 6,
    kNowPeekActKindActivation = 7,
    kNowPeekActKindVisibility = 8,
    kNowPeekActKindWindow = 9
};

/* What a request asks for. */
enum {
    kNowPeekActOpNone = 0,
    kNowPeekActOpMenu = 1,      /* arm the guarded MenuSelect patch    */
    kNowPeekActOpControl = 2,   /* arm the guarded TrackControl patch  */
    kNowPeekActOpWindow = 3,    /* move/resize/zoom/close - see below  */
    kNowPeekActOpTextGet = 4,   /* served in the hook, no patch        */
    kNowPeekActOpTextSet = 5,   /* served in the hook, no patch        */
    /* Prove the patch ABI against a known answer, in the target's own
       context. It exists because the ABI bug it catches is SILENT: a
       patch with the result slot in the wrong place reports firing and
       the application does nothing, because the value it read was never
       the value we wrote. A wrong ABI does not crash, it lies - so the
       mechanism has to be able to check itself. */
    kNowPeekActOpSelfTest = 6,
    /* Validate one observed DITL control item in the target context, then
       queue its press. No trap: the application's Dialog Manager path
       consumes the event itself. */
    kNowPeekActOpDialogItem = 7,
    /* A system Application-menu visibility command, served in the target
       process context. `item_index` carries kNowPeekActVisibility* so the
       V1 cell keeps every existing offset. */
    kNowPeekActOpVisibility = 8
};

enum {
    kNowPeekActVisibilityHide = 1,
    kNowPeekActVisibilityHideOthers = 2
};

/* kNowPeekActOpWindow sub-ops.
   Three of the four arm a patch. MOVE does not, and the reason is in the
   Toolbox's own signature: DragWindow returns void, so there is no
   question to answer and no application code that runs after it. The
   honest equivalent is to make the Window Manager call DragWindow would
   have made, in the target's own context - which is also what removes
   injected mouse motion, and with it the emulator, from this plane. */
enum {
    kNowPeekActWinMove = 1,   /* MoveWindow(w, h, v, false), in-context */
    kNowPeekActWinResize = 2, /* FindWindow->inGrow, GrowWindow->size   */
    kNowPeekActWinZoom = 3,   /* FindWindow->zoomPart, TrackBox->true   */
    kNowPeekActWinClose = 4,  /* FindWindow->inGoAway, TrackGoAway->true
                                 The application runs its OWN close path
                                 from there, save-changes dialog and all.
                                 Closing a window by calling CloseWindow
                                 ourselves would tear down a document
                                 behind the application's back. So this
                                 sub-op does not promise the window
                                 closes; it promises the application was
                                 ASKED, exactly as a user asks. */
    kNowPeekActWinSelect = 5  /* SelectWindow(w), in-context              */
};

/* FindWindow part codes (Inside Macintosh: Macintosh Toolbox Essentials,
   the Window Manager; MacWindows.h WindowPartCode). Named rather than
   spelled inline because there is a SECOND, similarly-named set - the
   WDEF message codes wInContent=1, wInDrag=2, wInGrow=3, wInGoAway=4,
   wInZoomIn=5, wInZoomOut=6 - and confusing the two is exactly the
   phantom-constant shape this project forbids. Upstream lost a day to
   the analogous confusion in the Control Manager's part codes. */
enum {
    kNowPeekActInDesk = 0,
    kNowPeekActInMenuBar = 1,
    kNowPeekActInSysWindow = 2,
    kNowPeekActInContent = 3,
    kNowPeekActInDrag = 4,
    kNowPeekActInGrow = 5,
    kNowPeekActInGoAway = 6,
    kNowPeekActInZoomIn = 7,
    kNowPeekActInZoomOut = 8
};

/* `armed` is a STAGE for the window op, not a flag, because two patches
   have to fire in order for one request. FindWindow may answer at either
   stage and leaves stage 2 behind it; the second patch may answer ONLY
   at stage 2. So the second patch can never fire without FindWindow
   having fired first for this same request - a stricter guard than a
   single flag, not a looser one.

   Why FindWindow answers at BOTH stages: upstream measured one posted
   click producing TWO FindWindow entries. A patch that answers only the
   first hands the application its part code and then lets the REAL
   FindWindow answer the second call with inContent - a truthful answer
   to a click at the window's centre, and one that sends the application
   down its content branch instead of its close branch. */
enum {
    kNowPeekActArmNone = 0,
    kNowPeekActArmReady = 1,   /* menu/control: fire. window: FindWindow */
    kNowPeekActArmStage2 = 2   /* window: Grow/TrackBox/TrackGoAway      */
};

/* Request lifecycle, written by the application (pending) and by the
   filter (done/error). Idle is the resting state and is what a withdrawn
   request is set back to - a request left pending is a patch waiting to
   fire on somebody else's click. */
enum {
    kNowPeekActStatusIdle = 0,
    kNowPeekActStatusPending = 1,
    kNowPeekActStatusDone = 2,
    kNowPeekActStatusError = 3
};

/* Small and specific, so a failure names itself rather than collapsing
   into one code the caller has to guess about. */
enum {
    kNowPeekActErrNone = 0,
    kNowPeekActErrBadOp = 1,
    kNowPeekActErrNoPatch = 2,     /* the trap patch was never installed */
    kNowPeekActErrBadWindowOp = 3, /* window_op is not a sub-op          */
    kNowPeekActErrNoWindow = 4,    /* window_ptr is zero                 */
    kNowPeekActErrAbi = 5,         /* selftest: answered, caller read
                                      something else - the result slot or
                                      the callee-pops contract is wrong  */
    /* The text ops. kNowPeekActErrNotOurWindow is a DIFFERENT condition
       from kNowPeekActErrNoWindow (not in this process's list, versus
       zero) and keeps its own code: collapsing two distinct failures
       onto one is how a specific error stops naming itself. */
    kNowPeekActErrNotOurWindow = 6,
    kNowPeekActErrNotDialog = 7,   /* windowKind != dialogKind           */
    kNowPeekActErrNoItem = 8,      /* item outside 1..CountDITL          */
    kNowPeekActErrBadTe = 9,       /* TEHandle NULL, out of the heap, or
                                      its inPort is not the named window */
    kNowPeekActErrTextKind = 10,
    kNowPeekActErrNotText = 11,    /* the item is not editText/statText  */
    /* The plane posts its own click - see NowPeekActCell.click_h - and
       the event queue can refuse it. Distinct from "armed and never
       taken": nothing was ever asked of the application. */
    kNowPeekActErrPostFailed = 12,
    kNowPeekActErrNotControlItem = 13,
    kNowPeekActErrItemMismatch = 14,
    kNowPeekActErrItemDisabled = 15,
    kNowPeekActErrIdentity = 16,
    kNowPeekActErrExpired = 17,
    kNowPeekActErrSessionChanged = 18
};

/* How a text request names its object. Every kind requires text_window,
   and that window must be in the SERVING process's window list. That is
   the identity check and it is the guard. */
enum {
    /* A dialog item by 1-based number, through GetDialogItem /
       GetDialogItemText / SetDialogItemText. */
    kNowPeekActTextDitem = 1,
    /* A TEHandle the caller names. Checked BOTH ways: the window must be
       ours, and the TERec's own inPort must be that window's port
       (TERec.inPort, TextEdit.h). A handle from another process fails,
       because its inPort names none of our windows. */
    kNowPeekActTextTe = 2,
    /* The dialog's own live TextEdit record - DialogRecord.textH. The
       discoverable route to a real TEHandle: the caller names only the
       window and the reply carries the handle used. */
    kNowPeekActTextDialogTe = 3
};

/* Which trap patches the plane actually installed, reported so the
   application can refuse a sub-op whose patch is absent instead of
   arming something that can never fire. */
enum {
    kNowPeekActPatchMenu = 1u << 0,
    kNowPeekActPatchControl = 1u << 1,
    kNowPeekActPatchFindWindow = 1u << 2,
    kNowPeekActPatchGrowWindow = 1u << 3,
    kNowPeekActPatchTrackBox = 1u << 4,
    kNowPeekActPatchTrackGoAway = 1u << 5
};

/* Text carried in a request or a reply. A dialog item's text is a Str255
   at the Dialog Manager boundary (GetDialogItemText takes a Str255), so
   255 is the honest ceiling for the ditem kind and the same buffer
   serves TE. A longer TE record is reported TRUNCATED with its true
   length in text_length, never silently clipped: a caller that cannot
   tell a short field from a clipped one has been told nothing.

   256 rather than 255 because it is a multiple of 4 and costs nothing -
   the same argument kNowPeekAnchorNameSize makes. Raw bytes, no length
   prefix: text_buf_length is the count. */
enum { kNowPeekActTextMax = 256 };

/* The act plane's one request/reply cell. ONE at a time by design: this
   is a single-consumer channel and the application is its only client.
   Coherence is the seqlock the anchors already use - `seq` is odd while
   the filter is writing, so a reader retries.

   Layout obeys the same rule as everything above: every field is 32
   bits, or 16-bit fields come in adjacent pairs, so no compiler inserts
   padding and the static asserts below hold under all three. */
typedef struct {
    NowPeekU32 seq;             /* odd while the filter writes           */
    NowPeekU32 op;              /* kNowPeekActOp*                        */
    NowPeekU32 status;          /* kNowPeekActStatus*                    */
    NowPeekU32 error;           /* kNowPeekActErr*                       */
    NowPeekU32 target_a5;       /* which A5 world this is addressed to.
                                   A5 rather than PSN because inside the
                                   hook the current A5 is one low-memory
                                   read, while a PSN would need Process
                                   Manager calls that are not safe there.
                                   The application already holds the
                                   mapping - P1 publishes A5 per process,
                                   which is what P1 is for.              */
    NowPeekU32 armed;           /* kNowPeekActArm*                       */
    NowPeekU32 fired;           /* a patch answered / MoveWindow ran     */
    NowPeekU32 served_a5;       /* the A5 that actually served it        */
    NowPeekU32 served_ticks;
    NowPeekU32 patches;         /* kNowPeekActPatch* actually installed  */

    /* menu */
    NowPeekI32 menu_id;
    NowPeekI32 item_index;      /* 1-based                               */
    NowPeekI32 arm_point_h;     /* the exact press the caller posted.
                                   Negative means unguarded, which only
                                   the selftest uses - it rides no user
                                   click at all. It is a diagnostic
                                   lever, not a mode anything ships in. */
    NowPeekI32 arm_point_v;

    /* control */
    NowPeekU32 control_handle;  /* the identity check for the control op */
    NowPeekI32 part_code;
    NowPeekU32 saw_action_proc; /* 0 none, 0xFFFFFFFF the Control
                                   Manager's "use the control's own"
                                   sentinel, else a real ProcPtr. Which
                                   of the three it is decides how a
                                   control is driven, so it is reported. */

    /* window */
    NowPeekU32 window_ptr;      /* identity check for the stage-2 traps  */
    NowPeekI32 window_op;       /* kNowPeekActWin*                       */
    NowPeekI32 win_h;           /* MOVE: global left. RESIZE: width      */
    NowPeekI32 win_v;           /* MOVE: global top.  RESIZE: height     */
    NowPeekI32 zoom_part;       /* ZOOM: kNowPeekActInZoomIn/Out         */
    NowPeekI32 click_h;         /* the exact point the caller posted     */
    NowPeekI32 click_v;
    NowPeekU32 find_window_fired;
    NowPeekU32 fw_answers;      /* how often FindWindow answered THIS
                                   request. More than one is the finding
                                   rather than a fault - see the arm
                                   stages above.                         */
    /* Unconditional entry counters, one per window trap, bumped at the
       TOP of each answer function before any guard runs. They answer the
       one question a guarded patch cannot answer about itself: when
       nothing happens, was the trap never called, or called and
       declined? Those are opposite repairs and without these they are
       the same symptom. 0 FindWindow, 1 GrowWindow, 2 TrackBox,
       3 TrackGoAway. */
    NowPeekU32 trap_hits[4];
    /* The same four, scoped to the request: bumped only when the current
       A5 is the target's AND a window request is armed. The global
       counters cannot tell our own click from another process's, which
       makes them ambiguous exactly where it matters. */
    NowPeekU32 trap_hits_target[4];

    /* text */
    NowPeekU32 text_kind;       /* kNowPeekActText*                      */
    NowPeekU32 text_window;     /* the WindowPtr / DialogPtr named       */
    NowPeekU32 text_handle;     /* kNowPeekActTextTe: the TEHandle       */
    NowPeekI32 text_item;       /* kNowPeekActTextDitem: 1-based         */
    NowPeekI32 text_length;     /* SET request: bytes in text_buf.
                                   Either reply: the object's TRUE length
                                   after the operation, which may exceed
                                   text_buf_length.                      */
    NowPeekI32 text_buf_length; /* reply: bytes actually in text_buf     */
    NowPeekI32 text_item_type;  /* reply: the item's type byte           */
    NowPeekU32 text_te;         /* reply: the TEHandle actually used     */

    /* selftest */
    NowPeekU32 selftest_want;
    NowPeekU32 selftest_got;

    unsigned char text_buf[kNowPeekActTextMax];
} NowPeekActCell;

/* One process's anchors, captured by the jGNE filter while that
   process's context is current - the only place its low-memory
   Window/Menu state is visible (finding observe-process-local-ui).
   The extension publishes ADDRESSES only; following them into a
   foreign heap is application code, never resident code. */
typedef struct {
    NowPeekU32 psn_high;      /* ProcessSerialNumber; 0/0 = empty slot */
    NowPeekU32 psn_low;
    NowPeekU32 a5;            /* CurrentA5 for that context */
    NowPeekU32 window_list;   /* low-memory WindowList head */
    NowPeekU32 menu_list;     /* low-memory MenuList */
    NowPeekU32 stamp_ticks;   /* TickCount at capture; 0 = never */
    /* V2. APPENDED, deliberately: stamp_ticks stays at offset 20 because
       readers use it as a seqlock - stamp, fields, stamp again - and a V1
       reader still finds it exactly where it left it.

       Note the field's position says nothing about when it is WRITTEN.
       capture_anchor fills this BEFORE committing the stamp, like every
       other field, or a reader could pair a fresh stamp with a stale
       stack base and never know. */
    NowPeekU32 stack_base;    /* LMGetCurStackBase for that context */
    /* V3. Appended again, by the same rule and for the same reason: the
       seqlock's stamp keeps offset 20, stack_base keeps 24, and a V1 or
       V2 reader finds every field it knows exactly where it left it.

       The process's own name (low-memory CurApName), captured in the
       same context as A5 - which is what makes it worth carrying. A5
       and stack_base are both ADDRESSES, so a recycled slot left behind
       by a dead application whose partition was reused can satisfy both
       and still be debris. The name is not an address: it survives the
       reuse and names the dead application, which is a discriminator
       neither root can supply.

       A Pascal string: cur_ap_name[0] is the length, 0 meaning the
       extension had none to give. Written BEFORE the stamp commits,
       like every other field.

       Not a promise of uniqueness - two copies of the same application
       share a name - so it can only ever REFUTE a slot, never elect
       one. The oracle uses it that way. */
    unsigned char cur_ap_name[kNowPeekAnchorNameSize];
} NowPeekAnchorSlot;

/* Source inputs and resident build are deliberately separate identities.
   Both are SHA-1 values represented as five aligned words; the final
   MacBinary digest is computed after Rez and never placed inside itself. */
typedef struct {
    NowPeekU32 source_manifest[kNowPeekIdentityWordCount];
    NowPeekU32 build_fingerprint[kNowPeekIdentityWordCount];
} NowPeekBuildIdentity;

/* The only application writer's renewable session. heartbeat_ticks is the
   publish-last commit word. The extension echoes owner_epoch only after the
   lease validates, so a replacement can distinguish its own accepted request
   from the dead writer's cells without taking ownership of arm_request. */
typedef struct {
    NowPeekU32 session_nonce_hi;
    NowPeekU32 session_nonce_lo;
    NowPeekU32 psn_high;
    NowPeekU32 psn_low;
    NowPeekU32 app_creator;
    NowPeekU32 app_name;
    NowPeekU32 heartbeat_ticks;
    NowPeekU32 owner_epoch;
    NowPeekU32 resident_owner_epoch;
} NowPeekWriterLease;

/* P2 semantic assist. The evidence and rejected alternatives behind this
   deliberately small operation set are in docs/p2-semantic-evidence.md.
   The records are fixed-size because this code runs from a system-wide event
   filter: no allocation, unbounded traversal, or caller-selected byte count
   is permitted. */
enum {
    kNowPeekSemanticFormatNone = 0,
    kNowPeekSemanticFormatV1 = 1,
    kNowPeekSemanticMaxRecords = 32,
    kNowPeekSemanticTextMax = 32,
    kNowPeekSemanticLeaseTicks = 120
};

enum {
    kNowPeekSemanticOpNone = 0,
    kNowPeekSemanticOpControlClass = 1,
    kNowPeekSemanticOpListCells = 2,
    kNowPeekSemanticOpSystemMenu = 3
};

enum {
    kNowPeekSemanticStatusNone = 0,
    kNowPeekSemanticStatusPending = 1,
    kNowPeekSemanticStatusOk = 2,
    kNowPeekSemanticStatusUnsupported = 3,
    kNowPeekSemanticStatusUnsupportedCustom = 4,
    kNowPeekSemanticStatusTruncated = 5,
    kNowPeekSemanticStatusInvalid = 6,
    kNowPeekSemanticStatusWrongTarget = 7,
    kNowPeekSemanticStatusStale = 8
};

enum {
    kNowPeekSemanticRecordNone = 0,
    kNowPeekSemanticRecordControlClass = 1,
    kNowPeekSemanticRecordListCell = 2,
    kNowPeekSemanticRecordMenuItem = 3
};

enum {
    kNowPeekSemanticControlUnknown = 0,
    kNowPeekSemanticControlStandard = 1,
    kNowPeekSemanticControlResource = 2,
    kNowPeekSemanticControlCustom = 3,
    kNowPeekSemanticRecordSelected = 1u << 0,
    kNowPeekSemanticRecordEnabled = 1u << 1,
    kNowPeekSemanticRecordChecked = 1u << 2,
    kNowPeekSemanticRecordSeparator = 1u << 3,
    kNowPeekSemanticRecordTextComplete = 1u << 4
};

/* All 16-bit fields are paired so the record is 48 bytes under all three
   compilers. `index` is the 1-based menu item or list row; `aux` is the list
   column or control class, and `flags` carries the record flag bits. Text has an
   explicit true length: when it exceeds the fixed buffer the whole response
   is truncated and the record never claims TextComplete. */
typedef struct {
    NowPeekU16 kind;
    NowPeekU16 status;
    NowPeekU16 index;
    NowPeekU16 aux;
    NowPeekU32 flags;
    NowPeekU16 text_length;
    NowPeekU16 text_copied;
    unsigned char text[kNowPeekSemanticTextMax];
} NowPeekSemanticRecord;

/* One request/reply cell. The application writes request fields and publishes
   request_generation LAST. The resident snapshots it, validates the exact A5
   and object tuple, writes response_generation odd while publishing, then
   writes the next nonzero even value LAST. A reader copies only between two
   equal even generation reads and rechecks every echoed identity. */
typedef struct {
    NowPeekU32 request_generation;
    NowPeekU32 request_op;
    NowPeekU32 request_writer_epoch;
    NowPeekU32 request_target_a5;
    NowPeekU32 request_scene_generation;
    NowPeekU32 request_window;
    NowPeekU32 request_object;
    NowPeekI32 request_object_aux;
    NowPeekU32 request_deadline_ticks;

    NowPeekU32 response_generation;
    NowPeekU32 response_request_generation;
    NowPeekU32 response_status;
    NowPeekU32 response_writer_epoch;
    NowPeekU32 response_target_a5;
    NowPeekU32 response_scene_generation;
    NowPeekU32 response_window;
    NowPeekU32 response_object;
    NowPeekI32 response_object_aux;
    NowPeekU32 response_served_ticks;
    NowPeekU16 response_record_count;
    NowPeekU16 response_total_count;
    NowPeekSemanticRecord records[kNowPeekSemanticMaxRecords];
} NowPeekSemanticCell;

/* V2 continuation of NowPeekActCell. It lives at the END of NowPeekTable:
   growing the embedded V1 cell would move content_block and every U2/U3
   field, silently breaking an older reader. The request identity is written
   by the one application writer and published by request_generation LAST.
   The resident echoes the entire tuple before advancing resident_stage.

   PSN is correlation, not resident authority. The resident safety boundary
   remains target_a5 plus the operation-specific object guards in the V1
   cell; Process Manager calls are not introduced into foreign context. */
typedef struct {
    NowPeekU32 request_generation;
    NowPeekU32 correlation_hi;
    NowPeekU32 correlation_lo;
    NowPeekU32 writer_epoch;
    NowPeekU32 target_a5;
    NowPeekU32 target_psn_high;
    NowPeekU32 target_psn_low;
    NowPeekU32 scene_generation;
    NowPeekU32 operation_kind;
    NowPeekU32 operation_code;
    NowPeekU32 operation_object;
    NowPeekI32 operation_aux;
    NowPeekU32 deadline_ticks;

    NowPeekU32 resident_generation;
    NowPeekU32 resident_request_generation;
    NowPeekU32 resident_correlation_hi;
    NowPeekU32 resident_correlation_lo;
    NowPeekU32 resident_writer_epoch;
    NowPeekU32 resident_target_a5;
    NowPeekU32 resident_target_psn_high;
    NowPeekU32 resident_target_psn_low;
    NowPeekU32 resident_scene_generation;
    NowPeekU32 resident_operation_kind;
    NowPeekU32 resident_operation_code;
    NowPeekU32 resident_operation_object;
    NowPeekI32 resident_operation_aux;
    NowPeekU32 resident_stage;
    NowPeekU32 resident_requested_ticks;
    NowPeekU32 resident_accepted_ticks;
    NowPeekU32 resident_armed_ticks;
    NowPeekU32 resident_fired_ticks;
    NowPeekU32 resident_terminal_ticks;
} NowPeekActV2Cell;

typedef struct {
    NowPeekU32 magic;         /* kNowPeekTableMagic */
    NowPeekU16 ext_major;     /* exact match required */
    NowPeekU16 ext_minor;     /* informational */
    NowPeekU32 length;        /* bytes valid; readers gate on >= */
    NowPeekU32 caps;          /* planes present in this binary */
    NowPeekU32 heartbeat;     /* TickCount at last filter pass */
    NowPeekU32 boot_ticks;    /* TickCount when the core installed */
    NowPeekU32 arm_request;   /* application writes: plane bits to arm */
    NowPeekU32 arm_active;    /* extension writes: plane bits armed */
    NowPeekU16 anchor_format; /* kNowPeekAnchorFormat* */
    NowPeekU16 anchor_count;  /* slots the filter maintains */
    NowPeekAnchorSlot anchors[kNowPeekMaxAnchors];
    /* P4. APPENDED after the anchor region, by the same rule the anchor
       slot's own V2/V3 fields were appended: every offset above is
       unchanged, so a reader that knows only P0/P1 finds every field it
       knows exactly where it left it, and a resident extension that
       predates this plane simply reports a shorter `length`.

       That is the whole stale-resident story, and it is deliberately NOT
       a second version number. An application requires act_format to be
       one it knows AND length to cover the cell; an older extension
       fails the second test, so a request is REFUSED rather than written
       into a block with no room for it. Silent corruption of a shared
       system-heap block would be the alternative, and it would leave the
       caller believing a guard was armed that does not exist.

       act_text_max is stated in the table rather than only in this
       header for the same reason: it is what the RESIDENT half was built
       with, so an application can bound a write by what the extension
       actually allocated instead of by what it was itself compiled
       against. */
    NowPeekU16 act_format;    /* kNowPeekActFormat* */
    NowPeekU16 act_text_max;  /* text_buf bytes this extension allocated */
    NowPeekActCell act;
    /* P3. Appended after P4 by the same accretive rule P4 was appended
       after the anchors: no existing offset moves, so no existing reader
       changes, and an extension that predates this plane simply reports
       a shorter `length` and a reader gates on it.

       This ONE WORD is the whole footprint of the content plane in this
       table - it is the address of a block the extension allocates in the
       system heap, and 0 means absent. The plane's own 64 KiB lives
       there and not here, because a ring in this table would be a ring
       every reader of every other plane has to carry past. */
    NowPeekU32 content_block;
    /* U2. Everything below is appended. Old P0-P4 offsets above remain
       byte-for-byte stable and old/short residents refuse these regions. */
    NowPeekU16 identity_format;
    NowPeekU16 identity_length;
    NowPeekBuildIdentity identity;
    NowPeekU16 writer_format;
    NowPeekU16 writer_length;
    NowPeekWriterLease writer;
    /* P1 hot-path evidence. These are observations, resident-written. */
    NowPeekU32 anchor_event_passes;
    NowPeekU32 anchor_slot_scans;
    NowPeekU32 anchor_full_publishes;
    NowPeekU32 anchor_change_publishes;
    NowPeekU32 anchor_cadence_publishes;
    NowPeekU32 anchor_last_publish_ticks;
    /* U3 P2 append. Old identity/writer/P1 evidence offsets stay stable. */
    NowPeekU16 semantic_format;
    NowPeekU16 semantic_length;
    NowPeekSemanticCell semantic;
    /* U5 P4 V2 append. This is the continuation of `act`, not a second
       channel. Everything above retains its historic offset. */
    NowPeekActV2Cell act_v2;
} NowPeekTable;

/* The offsets ARE the contract; a drift here is a defect on the other
   side of a compiler, not a build detail. */
_Static_assert(sizeof(NowPeekAnchorSlot) == 60, "slot size");
/* Unchanged from V1 on purpose: this offset is the seqlock's, and moving
   it would break a V1 reader silently rather than loudly. */
_Static_assert(offsetof(NowPeekAnchorSlot, stamp_ticks) == 20,
               "slot stamp offset");
_Static_assert(offsetof(NowPeekAnchorSlot, stack_base) == 24,
               "slot stack base offset");
/* V3's field is appended, so V2's two offsets above are unchanged and
   this one is the only new number. 32 bytes of unsigned char at a
   4-aligned offset leaves the slot 4-aligned and 60 bytes wide on every
   one of the three compilers - no padding anywhere, which is the whole
   layout rule stated at the top of this file. */
_Static_assert(offsetof(NowPeekAnchorSlot, cur_ap_name) == 28,
               "slot name offset");
_Static_assert(sizeof(((NowPeekAnchorSlot *)0)->cur_ap_name)
                   == kNowPeekAnchorNameSize,
               "slot name width");
_Static_assert(offsetof(NowPeekTable, ext_major) == 4, "major offset");
_Static_assert(offsetof(NowPeekTable, ext_minor) == 6, "minor offset");
_Static_assert(offsetof(NowPeekTable, length) == 8, "length offset");
_Static_assert(offsetof(NowPeekTable, caps) == 12, "caps offset");
_Static_assert(offsetof(NowPeekTable, heartbeat) == 16,
               "heartbeat offset");
_Static_assert(offsetof(NowPeekTable, boot_ticks) == 20,
               "boot ticks offset");
_Static_assert(offsetof(NowPeekTable, arm_request) == 24,
               "arm request offset");
_Static_assert(offsetof(NowPeekTable, arm_active) == 28,
               "arm active offset");
_Static_assert(offsetof(NowPeekTable, anchor_format) == 32,
               "anchor format offset");
_Static_assert(offsetof(NowPeekTable, anchor_count) == 34,
               "anchor count offset");
_Static_assert(offsetof(NowPeekTable, anchors) == 36, "anchors offset");

/* P4's offsets. The anchor region ends at 36 + 60*32 = 1956, and every
   number below is derived from that rather than restated, so a change to
   kNowPeekMaxAnchors moves the plane without any of these going quietly
   wrong. The cell itself is 44 four-byte fields (176) plus the text
   buffer, with no padding under any of the three compilers - which is
   the layout rule stated at the top of this file, and the asserts are
   how it is watched rather than assumed. */
_Static_assert(offsetof(NowPeekTable, act_format)
                   == 36 + 60 * kNowPeekMaxAnchors,
               "act format offset");
_Static_assert(offsetof(NowPeekTable, act_text_max)
                   == offsetof(NowPeekTable, act_format) + 2,
               "act text max offset");
_Static_assert(offsetof(NowPeekTable, act)
                   == offsetof(NowPeekTable, act_format) + 4,
               "act cell offset");
_Static_assert(offsetof(NowPeekActCell, text_buf) == 176,
               "act text buffer offset");
_Static_assert(sizeof(NowPeekActCell) == 176 + kNowPeekActTextMax,
               "act cell size");
_Static_assert(sizeof(((NowPeekActCell *)0)->text_buf) == kNowPeekActTextMax,
               "act text buffer width");
/* P3's one offset, derived from P4's end rather than restated - it asked
   for 36 + 60 * kNowPeekMaxAnchors, which is where P4 already is, and the
   correction is here rather than in a comment because an assert is the
   only form of this statement that stays true. */
_Static_assert(offsetof(NowPeekTable, content_block)
                   == offsetof(NowPeekTable, act) + sizeof(NowPeekActCell),
               "content block offset");
_Static_assert(offsetof(NowPeekTable, identity_format)
                   == offsetof(NowPeekTable, content_block) + 4,
               "identity append offset");
_Static_assert(offsetof(NowPeekTable, identity)
                   == offsetof(NowPeekTable, identity_format) + 4,
               "identity payload offset");
_Static_assert(sizeof(NowPeekBuildIdentity) == 40,
               "identity payload size");
_Static_assert(offsetof(NowPeekTable, writer_format)
                   == offsetof(NowPeekTable, identity) + 40,
               "writer append offset");
_Static_assert(offsetof(NowPeekTable, writer)
                   == offsetof(NowPeekTable, writer_format) + 4,
               "writer payload offset");
_Static_assert(sizeof(NowPeekWriterLease) == 36,
               "writer payload size");
_Static_assert(offsetof(NowPeekTable, anchor_event_passes)
                   == offsetof(NowPeekTable, writer) + 36,
               "P1 counters append offset");
_Static_assert(offsetof(NowPeekTable, act_v2)
                   == offsetof(NowPeekTable, semantic)
                    + sizeof(NowPeekSemanticCell),
               "act v2 append offset");
_Static_assert(sizeof(NowPeekActV2Cell) == 32 * 4,
               "act v2 cell size");
_Static_assert(sizeof(NowPeekTable)
                   == offsetof(NowPeekTable, act_v2)
                    + sizeof(NowPeekActV2Cell),
               "table size");
_Static_assert(sizeof(NowPeekSemanticRecord) == 48,
               "semantic record size");
_Static_assert(offsetof(NowPeekTable, semantic_format)
                   == offsetof(NowPeekTable, anchor_last_publish_ticks) + 4,
               "semantic append offset");
_Static_assert(offsetof(NowPeekTable, semantic)
                   == offsetof(NowPeekTable, semantic_format) + 4,
               "semantic cell offset");
_Static_assert(offsetof(NowPeekSemanticCell, records) == 80,
               "semantic records offset");
_Static_assert(sizeof(NowPeekSemanticCell)
                   == 80 + 48 * kNowPeekSemanticMaxRecords,
               "semantic cell size");

#endif /* NOW_PEEK_TABLE_H */
