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
    kNowPeekActFormatV1 = 1,    /* the cell as it shipped through menuact/
                                   ctlact/winact/text - no key, no menugeom */
    /* + kNowPeekActOpKey, kNowPeekActOpMenuGeom below. EXACT match, same
       as V1 was: this cell has no accretive-length story of its own (that
       is what `length` and act_format TOGETHER already gate at the TABLE
       level - see the stale-resident note above); a V1 resident simply
       does not have the fields a V2 request would write into, so it is
       refused by format rather than partially trusted. Landed 2026-08-01
       with a guest and an extension that ship as one pair - a V1
       extension paired with a V2 application (or the reverse) is refused,
       not degraded, which is the honest outcome for two halves that no
       longer agree on what this cell means. */
    kNowPeekActFormatV2 = 2,
    /* + click_not_a5 / click_pending / click_posted below, which move WHERE the
       click is posted from rather than adding an op. Same exact-match
       discipline: a V2 resident posts the click in the target's own hook
       and has no field to tell it otherwise, so pairing it with a V3
       application would leave every click-driven request armed and
       unclicked - refused by format rather than half-served. */
    kNowPeekActFormatV3 = 3,
    /* + NowPeekActPump and the two verb-trap counter pairs, both appended
       at the END of the table (see NowPeekActPump). Same exact-match
       discipline again, and for the sharpest reason yet: the pump
       handshake is the only route a click has that has any prospect of
       DELIVERING on this machine, and a V3 resident half would silently
       keep the route that does not - a plane that looks armed and never
       fires. Extension, application and pump are built from this header
       together. */
    kNowPeekActFormatV4 = 4
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

    /* V2. Both served OUTRIGHT in the hook, like the text ops: neither
       arms a patch, because neither answers a trap the application calls
       - one queues an event, the other reads a menu's own MDEF, and both
       are done by the time status flips to done. */

    /* Post ONE keystroke WITH modifiers. Reachable only from here: the
       modifier bits live on the Event Manager's queue ELEMENT, and
       PPostEvent is the only call that hands that element back
       (CALL_NOT_IN_CARBON - absent from the Carbon Events.h the
       application builds against). The application's own `key` verb
       posts an unmodified keystroke directly and refuses a modifier
       rather than dropping it silently; THIS op is what a refusal for
       mods != 0 now routes through instead of a flat wall - see
       act.key_mods below and docs/open-issues.md. */
    kNowPeekActOpKey = 7,
    /* Read ONE menu's per-item geometry, as its own MDEF computes it
       (mCalcItemMsg) - not a guess from a fixed row height. GetMenuHandle
       and a menu's MDEF Handle are only meaningful in the OWNING
       process's context, which is why this is served here rather than
       answered from the table alone. */
    kNowPeekActOpMenuGeom = 8
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
    kNowPeekActWinClose = 4   /* FindWindow->inGoAway, TrackGoAway->true
                                 The application runs its OWN close path
                                 from there, save-changes dialog and all.
                                 Closing a window by calling CloseWindow
                                 ourselves would tear down a document
                                 behind the application's back. So this
                                 sub-op does not promise the window
                                 closes; it promises the application was
                                 ASKED, exactly as a user asks. */
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
    /* menugeom named a menu ID that GetMenuHandle does not know, or one
       whose MDEF Handle is empty - a menu this process never installed
       has neither, and there is no rect to report for it. */
    kNowPeekActErrNoMenu = 13
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

/* menugeom's reply, one per item, in the field order a QuickDraw Rect
   is actually stored in (top, left, bottom, right - Imaging With
   QuickDraw) because that is what the MDEF's mCalcItemMsg fills; a
   caller that wants a CGRect/NSRect does that reordering, not this
   table. Four 16-bit fields, 8 bytes, so an array of these stays
   4-aligned under the header's own layout rule with no padding. */
typedef struct {
    NowPeekU16 top;
    NowPeekU16 left;
    NowPeekU16 bottom;
    NowPeekU16 right;
} NowPeekActMenuRect;

/* Capped so the reply UNIONS with text_buf below rather than growing the
   cell: this plane is a single request at a time by design, so a
   menugeom answer and a text answer are never live together, and the
   larger of the two already bounds the block. 32 * 8 == kNowPeekActTextMax
   exactly - pinned by the static assert beside the cell, not restated
   here, so a change to either constant is caught rather than trusted. */
enum { kNowPeekActMenuItemMax = kNowPeekActTextMax / 8 };

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

    /* key (V2). Served outright - see kNowPeekActOpKey above. code/char
       are exactly what PostEvent's message already carries (high byte,
       low byte); mods is evtQModifiers, which only THIS context can
       stamp on the queue element PPostEvent hands back. */
    NowPeekI32 key_code;
    NowPeekI32 key_char;
    NowPeekU32 key_mods;

    /* menugeom (V2). menu_id is the SAME field the menu op already uses
       above - one request at a time, one meaning per request, and this
       op does not also need a menu op pending. The per-item rects are in
       the union below. */
    NowPeekI32 menu_item_count; /* items the MDEF answered, capped at
                                   kNowPeekActMenuItemMax                  */
    NowPeekI32 menu_width;
    NowPeekI32 menu_height;

    /* WHERE THE CLICK IS POSTED FROM (V3).
       Every click-driven op (menu, control, the three window ops that
       arm) needs a mouseDown in the system event queue, and until V3 the
       hook queued it in the TARGET's own context, on the same pass that
       armed - which reads as the tidy thing to do and measured 0/10 on
       every op across two sessions. A keyDown queued from that same
       place is delivered (`key` with modifiers actuates from it), so the
       context is not inert; a mouseDown queued from it is not, on this
       machine, and the global FindWindow entry counter does not move,
       which says the application never saw the press at all.
       The sibling Mirror project queues its click from the AGENT's own
       process, after the target has armed and said so, and measures
       20/20 on the four window ops. That is the one structural
       difference between the two, so it is the one this plane now
       copies: the application names ITS OWN A5 world here and the hook
       posts the click on a pass running THERE, leaving the target's own
       pass to do nothing but arm.
       click_not_a5 names the world that must NOT post it - the target's,
       the one whose pass arms - rather than naming the one that must,
       because WHICH other process posts it does not matter and pinning
       it to one does. The application's first attempt named its own A5
       and measured 0/6 with the ask never served at all: this Carbon
       application's background WaitNextEvent does not reach the resident
       hook the way a classic binary's does, and a mechanism that depends
       on it is a mechanism that depends on CarbonLib's event
       reimplementation. Any process that pumps will do, and on an idle
       Mac OS 9 there are always several.
       click_pending is the ask, cleared by whichever pass serves it;
       click_posted is the answer, so an application that never sees the
       flag clear can say whether PPostEvent refused or no other process
       pumped in time. */
    NowPeekU32 click_not_a5;
    NowPeekU32 click_pending;
    NowPeekU32 click_posted;
    /* Whose passes ran while the ask stood, and how many. Without these
       "the click never left" is one symptom over two opposite repairs:
       no pass reached the hook at all (the ask is unservable where it was
       put), or a pass ran and PPostEvent refused the queue element. */
    NowPeekU32 click_passes;
    NowPeekU32 click_last_a5;

    /* ONE of these at a time, by the cell's own single-request design
       stated above - a menugeom answer and a text answer are never live
       together, so the rect array rides in the text buffer's own bytes
       rather than growing the resident block for a plane that is not
       active. Anonymous, so every existing `cell->text_buf` reference is
       unchanged: the layout is new here, the access is not. */
    union {
        unsigned char      text_buf[kNowPeekActTextMax];
        NowPeekActMenuRect menu_item_rects[kNowPeekActMenuItemMax];
    };
} NowPeekActCell;

/* ======================================================================
   P4b - THE ACT PUMP HANDSHAKE (V4)
   ======================================================================

   WHY THERE IS A SECOND PROCESS AT ALL. Three of the act ops (menu,
   control, and three of the four window sub-ops) arm a guarded trap
   patch and then need the application to CALL that trap - which a real
   user does by clicking. So something has to queue a mouseDown the
   application will dequeue, with `where` under our control.

   V3 moved that press OFF the pass that arms, to a pass belonging to any
   process but the target's (click_not_a5, above). It measured 0/5, and
   the measurement said why: 293-303 act passes in five seconds and every
   single one of them in the TARGET's own A5 world. There was no other
   process pumping. A background Carbon application's WaitNextEvent does
   not fall through to the classic Event Manager, so the resident filter
   never runs for the guest application either - which closes the two
   remaining candidates, and each is closed by a measurement rather than
   by taste:

     - the PPC application cannot post: PPostEvent and the low-memory
       mouse globals are CALL_NOT_IN_CARBON (Events.h), and PostEvent
       hands back no queue element to stamp `where` on;
     - the resident filter CAN call PPostEvent - it is 68K and not Carbon
       - and does; it simply never gets a pass anywhere but in the target
       (docs/open-issues.md, act-click-no-pass);
     - injecting mouse MOTION would need the emulator's QMP, which is not
       available on metal and is forbidden in the act plane.

   So V3's rule is right and had nobody to obey it. V4 supplies the
   missing process rather than changing the rule: `now-pump`, a faceless
   68K background application with no wire of its own, whose entire
   interface is the ten words below.

   The sibling Mirror project answered the same question with an ordinary
   CLASSIC application posting from its own context after the target
   armed (mirror guest/app/src/mirrorverbs.c post_click_at, called from
   verb context) and measured 20/20 on each window op. NOTHING here
   inherits that measurement.

   THE HANDSHAKE, and it is deliberately one-way per word (the write
   discipline at the top of this file):

     the filter (in the target's context, having just armed)
        writes click_h/click_v/click_mods/click_count, THEN bumps
        click_pending - which is a COUNTER, not a flag, so that a reply
        left over from the previous request can never read as this
        request's. click_pending is the commit word. (The cell's own
        click_pending above is a FLAG and a different word; the two are
        the ask at two levels - the cell's is "a press is owed", this
        one is "ticket N is with the pump".)
     the pump (its own context, its own event loop)
        sees click_pending != click_posted, posts, then writes
        click_error and finally click_posted = the value it served.
     nobody else writes those six words.

   The pump is OPTIONAL, the way every resident-family component is
   (docs/resident-components.md): with no pump running, the filter falls
   back to V3's route exactly as it stands today and the plane degrades
   to precisely the behaviour the ledger already describes.
   now_act_click_route() states that choice once.

   THE LIFECYCLE, and why the heartbeat is in this table rather than in a
   protocol. The application launches the pump when a host session begins
   and asks it to quit (Apple Event) when the session ends. Neither half
   of that survives a crash - a host that dies, or a guest application
   that Type-11s, leaves a faceless process running with no user
   interface to quit it and nothing on screen to say it is there. So the
   pump ALSO watches session_heartbeat and exits on its own when it goes
   stale. A component that can be orphaned by the failure of the thing
   that started it is not optional in any useful sense. */
enum {
    kNowPeekActPumpNone = 0,     /* no pump has ever written here      */
    kNowPeekActPumpRunning = 1,
    kNowPeekActPumpExiting = 2   /* written before the pump quits, so a
                                    reader can tell a clean exit from a
                                    crash: a crash leaves Running and a
                                    stale heartbeat.                   */
};

/* Ticks (60.15/second). Stated here because both sides read them, and
   the freshness rule is the whole lifecycle:

     SESSION - how long the application's heartbeat stays fresh. It is
       written every event-loop pass, so 10 seconds is many hundreds of
       missed passes: long enough that a busy guest is never mistaken for
       a dead one, short enough that an orphan does not outlive its
       session by a coffee break.
     PUMP - how long the pump's own heartbeat stays fresh, and therefore
       how long the filter keeps routing clicks to it. Shorter than the
       session window on purpose: routing a click to a pump that has
       stopped costs a whole request, while an application that thinks a
       session is alive for a few extra seconds costs nothing.
     GRACE - the pump's startup allowance. It launches before the
       application has necessarily written a first beat, and a pump that
       exited during its own launch would look exactly like a pump that
       never started. */
enum {
    kNowPeekActSessionTicks = 600,
    kNowPeekActPumpTicks = 300,
    kNowPeekActPumpGraceTicks = 1800
};

typedef struct {
    /* Application writes; pump and filter read. TickCount at the last
       pass of a live host session. 0 means no session has ever been
       open, which is a different state from a stale one and the pump
       treats it as such (see kNowPeekActPumpGraceTicks). */
    NowPeekU32 session_heartbeat;
    /* Pump writes; application and filter read. */
    NowPeekU32 pump_heartbeat;
    NowPeekU32 pump_state;      /* kNowPeekActPump*                    */
    /* The click handshake. See the note above for who writes what. */
    NowPeekU32 click_pending;   /* filter: request counter, the commit  */
    NowPeekU32 click_posted;    /* pump: the counter it has served      */
    NowPeekU32 click_error;     /* pump: kNowPeekActErr*, 0 = posted    */
    NowPeekI32 click_h;         /* filter: where, in global coordinates */
    NowPeekI32 click_v;
    NowPeekI32 click_mods;      /* filter: evtQModifiers to stamp       */
    NowPeekI32 click_count;     /* filter: 1..3 presses                 */
} NowPeekActPump;

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
    /* P4b. Appended at the END of the table, AFTER P3's word, and that
       placement is the whole of the accretive rule rather than an
       oversight: these fields belong to the act plane and would read
       better inside NowPeekActCell, but the cell is followed by
       content_block, so growing it would move P3's field under every
       reader that has one. The rule this file has followed since V2 of
       the anchor slot is that no existing offset moves; where a field
       reads best comes second. act_format V4 is what says these are
       here.

       The pump handshake and the session heartbeat, above. */
    NowPeekActPump act_pump;
    /* The two verb patches' unconditional entry counters, the exact
       analogue of NowPeekActCell.trap_hits for the four window traps -
       bumped at the TOP of each answer function, before any guard and
       whether or not the plane is armed.

       They exist because without them a menu request that does nothing
       reads identically whether MenuSelect was never called or was
       called and declined, and those are opposite repairs. That is not
       hypothetical: "0/10 menuact" is in the ledger with no way to tell
       the two apart, because only the four window patches ever called
       now_act_trap_hit. */
    NowPeekU32 act_menu_hits;
    NowPeekU32 act_menu_hits_target;    /* armed, menu op, our A5 */
    NowPeekU32 act_control_hits;
    NowPeekU32 act_control_hits_target;
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
   wrong. The cell itself is 50 four-byte fields (200, V2 - key_code
   through menu_height appended after selftest_got) plus the union that
   holds either the text buffer or menugeom's rects, with no padding
   under any of the three compilers - which is the layout rule stated at
   the top of this file, and the asserts are how it is watched rather
   than assumed. */
_Static_assert(offsetof(NowPeekTable, act_format)
                   == 36 + 60 * kNowPeekMaxAnchors,
               "act format offset");
_Static_assert(offsetof(NowPeekTable, act_text_max)
                   == offsetof(NowPeekTable, act_format) + 2,
               "act text max offset");
_Static_assert(offsetof(NowPeekTable, act)
                   == offsetof(NowPeekTable, act_format) + 4,
               "act cell offset");
_Static_assert(offsetof(NowPeekActCell, text_buf) == 220,
               "V3 act text buffer offset");
_Static_assert(sizeof(NowPeekActCell) == 220 + kNowPeekActTextMax,
               "V3 act cell size");
_Static_assert(sizeof(((NowPeekActCell *)0)->text_buf) == kNowPeekActTextMax,
               "act text buffer width");
/* menugeom's rects UNION with the text buffer rather than growing the
   cell - the design stated where kNowPeekActMenuItemMax is defined. This
   is the assert that pins it: if the two ever stop being the same size,
   the cell silently grows (the union's size becomes its larger member)
   and every offset after it is still correct but the "does not grow the
   block" claim above is no longer true. Caught here, not trusted. */
_Static_assert(sizeof(NowPeekActMenuRect) == 8, "menu rect size");
_Static_assert(sizeof(((NowPeekActCell *)0)->menu_item_rects)
                   == kNowPeekActTextMax,
               "menugeom rects union with the text buffer, not beside it");
/* P3's one offset, derived from P4's end rather than restated - it asked
   for 36 + 60 * kNowPeekMaxAnchors, which is where P4 already is, and the
   correction is here rather than in a comment because an assert is the
   only form of this statement that stays true. */
_Static_assert(offsetof(NowPeekTable, content_block)
                   == offsetof(NowPeekTable, act) + sizeof(NowPeekActCell),
               "content block offset");
/* P4b's offsets, derived from P3's end for the same reason P3's is
   derived from P4's: a restated number is a number that can drift. Ten
   32-bit words and four more, so the appended region needs no padding
   under any of the three compilers - the layout rule at the top of this
   file, held at the end of the table as well as in the middle of it. */
_Static_assert(sizeof(NowPeekActPump) == 40, "act pump size");
_Static_assert(offsetof(NowPeekTable, act_pump)
                   == offsetof(NowPeekTable, content_block) + 4,
               "act pump offset");
_Static_assert(offsetof(NowPeekTable, act_menu_hits)
                   == offsetof(NowPeekTable, act_pump)
                          + sizeof(NowPeekActPump),
               "act menu hits offset");
_Static_assert(offsetof(NowPeekTable, act_control_hits_target)
                   == offsetof(NowPeekTable, act_menu_hits) + 12,
               "act control hits offset");
_Static_assert(sizeof(NowPeekTable)
                   == 44 + 60 * kNowPeekMaxAnchors + sizeof(NowPeekActCell)
                          + sizeof(NowPeekActPump) + 16,
               "table size");

#endif /* NOW_PEEK_TABLE_H */
