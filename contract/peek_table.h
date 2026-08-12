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

   Write discipline: every cell names its writer; P9 is split explicitly
   into an application-owned mailbox and a resident-owned status block.
   One writer per word, both sides big-endian (same machine), no locks;
   stamp fields are the ordering signal - a reader treats a slot as valid
   only when its stamp is nonzero and fresh enough for the reader's purpose.
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
#include "resident_version.h"

/* Spelled out so no compiler warns about multi-character constants. */
#define NOW_PEEK_4CC(a, b, c, d)                                      \
    (((NowPeekU32)(a) << 24) | ((NowPeekU32)(b) << 16)                \
     | ((NowPeekU32)(c) << 8) | (NowPeekU32)(d))

enum {
    /* Gestalt selector 'NWex'; response is the table address. */
    kNowPeekGestaltSelector = (long)NOW_PEEK_4CC('N', 'W', 'e', 'x'),
    /* First prelude field; a table without it is not a table. */
    kNowPeekTableMagic = (long)NOW_PEEK_4CC('N', 'W', 'p', 't'),

    /* Major is exact-match compatibility: bump it only when an existing
       field's meaning changes. Minor is the intentional resident release
       sequence; development builds sharing it are distinguished by the build
       fingerprint below. New fields still ride on length rather than
       compatibility guesses. */
    kNowPeekExtMajor = NOW_RESIDENT_VERSION_MAJOR,
    kNowPeekExtMinor = NOW_RESIDENT_VERSION_MINOR,

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
    kNowPeekTableCapContent = 1u << 3,  /* P3: the content plane */
    kNowPeekTableCapEvents = 1u << 4,   /* P5: the transition tail */
    /* P6: the liveness channel. The resident dials the host ITSELF and
       keeps that connection alive, so a starved machine still answers
       for itself — measured 2026-08-05, a Finder modal starved every
       application on the guest for over 90 s, past the host's silence
       window, and the wire died against a healthy Macintosh. */
    kNowPeekTableCapLiveness = 1u << 5,
    /* P6, the second half: this binary CAN reach a transport and dial.
       Separate from the bit above because the two are separately true —
       the vehicle shipped and was proven on an emulator for a day before
       anything could dial — and because capabilities are bits and are
       never inferred from a version.

       **Corrected 2026-08-07, and the correction is the rule this enum
       already stated.** It used to be set only once a TCP stream actually
       existed, which made it a state word wearing a capability's name. It
       read correctly for as long as the resident opened its transport
       unconditionally at boot; the moment that became conditional on an
       application asking, a resting machine advertised one fewer
       capability than its binary had, and the bake gate — which derives
       the expected word from this enum — called it a plane that failed to
       arm. It was not: nothing had asked it to.

       So this says what the BINARY can do, like every bit beside it.
       Whether a stream exists right now is `channel_state`, and whether
       one is being held is `kNowPeekRestTransport`. Three questions,
       three words, which is the same separation `rest_state` exists to
       make. */
    kNowPeekTableCapLivenessNet = 1u << 6,
    /* P7: the DRAG vehicle — a mouse button that stays down across a
       gesture the application is inside, and a resident that releases it
       whether or not anybody asks.

       Its own bit rather than a version of P4's, because it is a
       different vehicle and not a new op on the old one. P4's whole
       input mechanism (`act_post_click`) queues a mouseDown and its
       mouseUp in one call at jGNE time; a drag cannot be served that way
       at all, because during `DragGrayRgn` the application is NOT in
       GetNextEvent and the jGNE filter is never re-entered. So P7 brings
       a Time Manager task, which runs whether or not anything is being
       scheduled — the same argument P6 makes for the same reason.

       A build without this bit refuses a drag rather than arming a
       vehicle that cannot fire. */
    kNowPeekTableCapDrag = 1u << 7,
    /* P8: the drawn cursor follows what the plane acts on.

       A COSMETIC-SOUNDING PLANE THAT IS NOT COSMETIC. Until it, the
       guest's sprite sat wherever it was last really drawn while every
       act and every drag happened somewhere else — so a screendump was
       evidence of what the machine looked like and never evidence of
       where we acted, software that draws relative to the pointer was a
       permanent special case, and a person at the machine watched a
       possessed Macintosh click on things with the arrow parked
       elsewhere.

       Its own bit rather than a part of P7's because it is a different
       call to a different manager, and because it must be able to be
       ABSENT: the bit is published only when `_CursorDeviceDispatch` is
       implemented AND the Cursor Device Manager owned up to a device.
       Without it every act and every drag behaves exactly as before,
       which is the resident-component charter's rule, and the picture is
       the only thing missing. */
    kNowPeekTableCapCursor = 1u << 8,
    /* P9: Continuity's resident input vehicle. The PowerPC application
       owns network intake; this bit says the resident can consume its
       bounded latest-state cell while another application is tracking. */
    kNowPeekTableCapContinuity = 1u << 9
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

   Ported from the parked sibling Mirror project's Portal INIT, whose
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
    kNowPeekActKindWindow = 9,
    /* P7. A drag press has no guest OBJECT the way a control or a dialog
       item does - it names a point, and the point is not an identity.
       What it binds instead is the SESSION nonce, which is unique to one
       gesture and is exactly what a stale request must not match. */
    kNowPeekActKindDrag = 10,
    /* P8 adjunct: place the drawn cursor in one observed window's owning
       process without also clicking, selecting, or changing front order. */
    kNowPeekActKindCursor = 11
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
    kNowPeekActOpVisibility = 8,
    /* Begin a drag: queue a mouseDown at (click_h, click_v) in the
       target's own context and LEAVE THE BUTTON DOWN, handing the
       gesture to the resident's drag vehicle (P7, below).

       There is deliberately no matching OpDragMove and no OpDragRelease,
       and the absence is the design rather than an omission. Once the
       button is down the application is inside its own tracking loop —
       `DragGrayRgn` reading `StillDown`/`GetMouse` — and is not calling
       GetNextEvent, so the jGNE filter that serves every op above is
       never re-entered and could not serve them. Motion and release are
       written straight into `NowPeekDragCell` and consumed by the Time
       Manager task, which fires regardless of who is scheduled.

       So: the press is a REQUEST (it needs the target's context, its
       identity check and its A5). The rest of the gesture is a SESSION. */
    kNowPeekActOpDragPress = 9,
    kNowPeekActOpCursorPlace = 10
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
    kNowPeekActErrSessionChanged = 18,
    /* P7. A drag is already in flight. Single-flight for the same reason
       the act cell is: there is one mouse button. */
    kNowPeekActErrDragBusy = 19,
    /* The resident has no drag vehicle — the Time Manager task never
       installed, or this build predates P7. Distinct from Busy and from
       PostFailed: nothing was asked of the application, and the repair is
       a different resident, not a retry. */
    kNowPeekActErrDragNoVehicle = 20
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
                                   lever, not a mode anything ships in.

                                   P7 REUSES THIS PAIR as a drag press's
                                   DESTINATION, global, valid only when
                                   zoom_part is non-zero. The accretive
                                   rule asks for a field with no meaning
                                   for the op over a new one, and a menu
                                   guard point is meaningless to a drag.
                                   The pair is read once, at
                                   kNowPeekActOpDragPress, and nowhere
                                   else. */
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
    NowPeekI32 zoom_part;       /* ZOOM: kNowPeekActInZoomIn/Out.
                                   P7 DRAG PRESS: non-zero means
                                   arm_point_h/v carry a destination.
                                   A separate flag rather than a
                                   sentinel coordinate, because every
                                   coordinate on a Macintosh screen is
                                   a legal destination and 0,0 most of
                                   all - the corner an unpopulated
                                   rectangle already silently pressed at
                                   once. */
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

/* ======================================================================
   P7 - THE DRAG VEHICLE
   ======================================================================

   P4 above can click. It cannot HOLD, and the difference is not a matter
   of degree. `act_post_click` queues a mouseDown and its mouseUp in one
   call, from the jGNE filter, and returns; every op in P4 is that shape.
   A drag needs three things none of which that shape can give:

   1. A press whose release is not already queued.
   2. Motion delivered WHILE the button is down. The Finder's own drag
      loop reads `StillDown`, `GetMouse` and `WaitMouseUp`, all of which
      read the mouse low-memory globals - so motion is a sequence of
      writes to those globals. But the application is INSIDE that loop
      and is therefore not calling GetNextEvent, so the jGNE filter is
      never re-entered and cannot deliver them. The vehicle must be an
      interrupt-time one: a Time Manager task, for the same reason P6 is.
   3. A release.

   And then the fourth thing, which is not a feature but the price of the
   other three:

   4. A DEAD-MAN RELEASE THE RESIDENT ENFORCES ITSELF.

   A guest left with the button down sits in the Finder's tracking loop
   forever, and the host cannot rescue it: the host's only channel into
   the guest is the same cell the wedged application has stopped reading.
   So the release cannot be something the host is trusted to send. The
   resident carries a deadline and releases the button when it expires,
   whether or not anybody asked - including when the host process was
   killed between the press and the release, which is the case that
   motivates the whole design.

   TWO deadlines, and either fires:

   - `idle_deadline` - ticks of silence tolerated since the last thing the
     HOST asked for. It catches a dead host.
   - `max_ticks` - the whole gesture's ceiling, refreshed by nothing at
     all. It catches a host that is alive and heartbeating with a wedged
     idea of what it is doing. One timer that the thing it measures can
     refresh is not a timeout (finding instrument-feeds-the-clock); this
     is why there are two, and why only one of them is refreshable.

   BOTH ARE CLAMPED BY THE RESIDENT, not by the caller. A host that
   writes 0, or 0xFFFFFFFF, or forgets the field entirely must not be
   able to switch the dead-man off - so the resident treats these as
   requests inside a range it owns. That is the one place in this header
   where the application's number is advisory.

   WHAT THE HEARTBEAT MUST MEAN. `heartbeat_ticks` is the HOST's
   liveness relayed through the guest application, never the guest
   application's own idle pump. An application that refreshed it from its
   event loop would keep a dead host's drag alive forever and the
   dead-man would measure nothing. The application refreshes it only when
   a drag message actually arrives from a face. */
enum {
    kNowPeekDragFormatNone = 0,
    kNowPeekDragFormatV1 = 1
};

enum {
    kNowPeekDragStateIdle = 0,
    /* The button is down and the Time Manager task owns the gesture. */
    kNowPeekDragStateHeld = 1,
    /* The button has been written up and the session is finished. It
       stays here, with its end_reason, until the next press clears it:
       a session that vanished on completion could not tell a host that
       came back late WHY its drag ended. */
    kNowPeekDragStateEnded = 2
};

/* Why a drag ended. The four are separately actionable and a single
   "done" would make them one - which is the whole complaint P4's error
   enum makes about collapsing failures. */
enum {
    kNowPeekDragEndNone = 0,        /* still held */
    kNowPeekDragEndReleased = 1,    /* the host asked, and it happened */
    /* The dead-man. Two codes, because the repairs differ: an idle
       expiry says the host stopped talking, a cap expiry says it never
       stopped and never finished. */
    kNowPeekDragEndDeadManIdle = 2,
    kNowPeekDragEndDeadManCap = 3,
    /* The table's writer lease changed under the session, or the plane
       was disarmed. The button still goes up - that is not optional -
       but the gesture was not completed and must never be reported as
       though it were. */
    kNowPeekDragEndSessionLost = 4
};

/* The clamps the resident applies to whatever the caller asked for.
   Stated once, here, because a limit that lives in the sender and again
   in the receiver is the defect class this project has paid for most.

   60 ticks = 1 s of silence, and 1800 = 30 s of gesture. Both are
   deliberately short: a drag is a hand movement, and the cost of ending
   one early is a snap-back, while the cost of ending one late is a
   machine nobody can use. */
enum {
    kNowPeekDragIdleMinTicks = 15,
    kNowPeekDragIdleMaxTicks = 300,
    kNowPeekDragIdleDefaultTicks = 60,
    kNowPeekDragCapMinTicks = 60,
    kNowPeekDragCapMaxTicks = 1800,
    kNowPeekDragCapDefaultTicks = 600,
    /* How often the vehicle fires. 16 ms is roughly a frame and is what
       the mouse VBL itself runs at; faster buys nothing a tracking loop
       can see, and slower makes the dead-man coarse. */
    kNowPeekDragTickMs = 16
};

/* One drag session. Its own cell rather than more fields on the act cell
   because it is not a request: it is a state two contexts share, written
   at both ends, and outliving many jGNE passes.

   `seq` is the seqlock the rest of this table uses - odd while the
   RESIDENT writes. The application's own writes are single words
   committed by `want_seq` and `release_request`, so they need no lock:
   the resident reads each of them once per tick and a torn 32-bit read
   is not a thing either compiler produces here.

   Layout obeys the same rule as everything above: every field is 32 bits
   wide, so no compiler inserts padding and the asserts below hold under
   all three. */
typedef struct {
    NowPeekU32 seq;             /* odd while the resident writes         */
    NowPeekU32 state;           /* kNowPeekDragState*                    */
    /* Allocated by the press and named by everything after it. A release
       that names a stale session is DROPPED rather than obeyed: without
       this, a release for a gesture that already timed out would end the
       next one, and the two are indistinguishable from the cell alone. */
    NowPeekU32 session;
    NowPeekU32 target_a5;       /* the A5 world the press was served in  */

    /* ---- written by the APPLICATION ---------------------------------- */
    NowPeekI32 want_h;          /* where the host wants the pointer      */
    NowPeekI32 want_v;
    /* The commit word for want_h/want_v, bumped AFTER them. The resident
       acts on a want only when this changes, so a half-written point is
       never consumed - the same discipline endpoint_epoch uses. */
    NowPeekU32 want_seq;
    /* The HOST's liveness, relayed. See the header above: never the
       guest application's own idle. */
    NowPeekU32 heartbeat_ticks;
    /* The session nonce to release, or 0. Not a boolean, so that a
       release cannot be for "whatever is running". */
    NowPeekU32 release_request;
    NowPeekU32 idle_deadline;   /* requested; the resident clamps it     */
    NowPeekU32 max_ticks;       /* requested; the resident clamps it     */

    /* ---- written by the RESIDENT ------------------------------------- */
    NowPeekI32 at_h;            /* where the pointer actually is         */
    NowPeekI32 at_v;
    NowPeekI32 origin_h;        /* where the press landed                */
    NowPeekI32 origin_v;
    NowPeekU32 begin_ticks;
    NowPeekU32 last_want_ticks; /* when the last new want was consumed   */
    NowPeekU32 end_reason;      /* kNowPeekDragEnd*                      */
    NowPeekU32 end_ticks;
    /* The clamped values actually in force, reported so a caller can see
       that its request was narrowed rather than obeyed. A clamp nobody
       can observe is indistinguishable from a caller being right. */
    NowPeekU32 idle_in_force;
    NowPeekU32 cap_in_force;
    /* Evidence the vehicle RAN, in the same shape liveness_ticks is: a
       count, not a timestamp, because a stopped clock and a stopped task
       look identical in a timestamp. */
    NowPeekU32 ticks_served;
    /* The LAST want this vehicle consumed, not a count of them - and the
       difference is the useful part. A host that moves the pointer
       faster than the vehicle fires will see this skip values, which is
       exactly the fact "3 moves applied" would hide: the gesture is
       being sampled, not replayed. */
    NowPeekU32 moves_applied;
    /* The button has been written up and a mouseUp EVENT is still owed.
       The two halves are separated on purpose. Writing the low-memory
       button state is what every tracking loop reads and is the part
       that must never fail, so the resident does it at interrupt time
       where nothing can refuse it. Queueing the event needs the target's
       own context and PPostEvent, so the jGNE pass does that on its next
       entry - which happens as soon as the tracking loop, now seeing the
       button up, returns the application to GetNextEvent. */
    NowPeekU32 pending_mouseup;
    /* What the resident last wrote to MBState: 1 down, 0 up. It is the
       one fact a person looking at a wedged machine most needs, and
       deriving it from `state` would be a guess. */
    NowPeekU32 button_down;
} NowPeekDragCell;

/* Which route the resident used to put the drawn cursor somewhere. */
enum {
    kNowPeekCursorRouteNone = 0,   /* no vehicle: the sprite is unmoved */
    kNowPeekCursorRouteDevice = 1, /* CursorDeviceMoveTo — the one that
                                      actually redraws */
    kNowPeekCursorRouteLowMem = 2, /* the CrsrNew/CrsrCouple recipe: the
                                      Toolbox follows, the picture does
                                      not. Kept as a fallback, and
                                      REPORTED as a distinct route so a
                                      machine falling back is not read as
                                      a machine that worked. */
    kNowPeekCursorRouteYielded = 3, /* declined: somebody else is driving
                                       this pointer */
    /* HideCursor/ShowCursor, from the target application's own context.
       The only route measured to actually move the picture on Mac OS 9;
       the other two set state the drawing path does not consult. It
       needs a real context and so is unreachable from interrupt time,
       which is why there is still a device route and why a DRAG is
       expected to report `device` and stay invisible. */
    kNowPeekCursorRouteQuickDraw = 4
};

/* What the caller knows about the context it is calling from. Both facts
   are the CALLER's and neither can be worked out here, which is why they
   are passed rather than inferred - the first version inferred the
   second from the first, because the drag happened to be the only
   interrupt-time caller, and an accidental coupling like that is a
   defect waiting for the second one. */
enum {
    /* The caller holds the pointer for the length of a gesture and must
       never yield to another mover - mid-drag, the plane IS the mover. */
    kNowCursorPlaceOwned = 1u << 0,
    /* No Toolbox beyond low-memory accessors may be called. */
    kNowCursorPlaceInterrupt = 1u << 1,
    /* The PowerPC NOW application, not the global jGNE filter, owns the
       balanced task-time redraw for this placement. Continuity uses this
       route so its resident never enters Cursor Device, QuickDraw, or Event
       Manager code on behalf of an arbitrary foreground process. */
    kNowCursorPlaceApplicationRedraw = 1u << 2
};

enum {
    kNowPeekCursorFormatV1 = 1,
    /* How long the resident refuses to move the sprite after motion it
       did not cause. Sixty ticks — one second. The number is small on
       purpose: this is not a lock, it is a courtesy, and a long one
       would make the cursor stop following for reasons nobody watching
       could explain. */
    kNowPeekCursorYieldTicks = 60
};

/* P8. Where the drawn cursor was last put, by which route, and how often
   the resident declined to put it anywhere.
 *
 * THE COUNTERS ARE THE POINT, not the position. A cursor plane that is
 * present, armed and silently taking the LOW-MEMORY route looks exactly
 * like one that is working, because both report a position and neither
 * throws an error — and only one of them moves the picture. That is the
 * defect this cell exists to make visible, and it is the defect this
 * plane was built to fix, so it would be the easiest one in the tree to
 * reintroduce without noticing. */
typedef struct {
    NowPeekU32 seq;            /* odd while the resident writes         */
    NowPeekU32 route;          /* kNowPeekCursorRoute*, the LAST one    */
    NowPeekI32 at_h;           /* where it was last asked to go         */
    NowPeekI32 at_v;
    NowPeekU32 asked;          /* placements requested                  */
    NowPeekU32 by_device;      /* served by CursorDeviceMoveTo          */
    NowPeekU32 by_lowmem;      /* served by the low-memory recipe       */
    /* Declined because the pointer had moved since we last placed it,
       and recently. A person at the machine is the case this counts, and
       counting it is what makes "we do not fight a human's pointer" a
       claim somebody can check rather than a sentence in a document. */
    NowPeekU32 yielded;
    NowPeekI32 last_err;       /* the CDM's last OSErr, 0 when none     */
    /* Non-zero when _CursorDeviceDispatch is implemented AND the manager
       answered with a device. Separate from the capability bit because
       the bit is published once at boot and this is what it was
       published FROM. */
    NowPeekU32 device_found;
} NowPeekCursorCell;

enum {
    kNowPeekContinuityFormatV1 = 1,
    /* V2 appends a resident 68K service entry. The PPC application invokes
       it through Mixed Mode from its cooperative wire pump; V1 is the
       metal-failed Time Manager route and must never be inferred as V2. */
    kNowPeekContinuityFormatV2 = 2,
    /* V3 moves Cursor Device ownership and placement into the PPC application.
       Apple requires PowerPC callers to use CursorDevicesGlue because the
       original ROM Mixed Mode transition for this manager is wrong. The
       resident now publishes a requested point, the app calls the official
       glue from cooperative task time, and the resident commits the result. */
    kNowPeekContinuityFormatV3 = 3,
    /* V4 activates the primary-button generation already carried by the UDP
       wire. Cursor Device Manager calls remain in the cooperative PPC
       application; the resident owns only tracking-loop MouseLocation and an
       unconditional MBState-up escape. */
    kNowPeekContinuityFormatV4 = 4,
    /* V5 appends host-selected tracking experiments and their counters. The
       experiments are inactive by default and never mutate a physical Cursor
       Device or ADB-owned global. */
    kNowPeekContinuityFormatV5 = 5,
    /* V6 appends a passive ADB service-routine observer. The resident keeps
       the incumbent device handler and data pointer intact, records the
       packet and low-memory cursor state around that handler, and never
       changes an ADB packet. This is diagnostic scaffolding for determining
       which cursor authority owns the PowerBook drag snap-back. */
    kNowPeekContinuityFormatV6 = 6,
    /* V7 gives one opt-in experiment meaning to tracking_options bit 3:
       substitute tiny relative ADB packets with a bounded delta toward the
       latest host point. The default remains the V6 passive observer. */
    kNowPeekContinuityFormatV7 = 7,
    kNowPeekContinuityStateInactive = 0,
    kNowPeekContinuityStateArmed = 1,
    kNowPeekContinuityStateActive = 2,
    kNowPeekContinuityStateExited = 3,
    kNowPeekContinuityStateRefused = 4
};

enum {
    kNowPeekContinuityExitNone = 0,
    kNowPeekContinuityExitHostLeft = 1,
    kNowPeekContinuityExitGuestInput = 2,
    kNowPeekContinuityExitLeaseExpired = 3,
    kNowPeekContinuityExitDisarmed = 4,
    kNowPeekContinuityExitUnavailable = 5
};

enum {
    kNowPeekContinuityInside = 1u << 0,
    kNowPeekContinuityPrimaryDown = 1u << 1,
    kNowPeekContinuityKeepalive = 1u << 2,
    kNowPeekContinuityLeaseMinTicks = 15,
    kNowPeekContinuityLeaseMaxTicks = 600,
    kNowPeekContinuityLeaseDefaultTicks = 90,
    /* Authority has crossed TCP but UDP is not live yet. No button can be
       held in this state, so setup gets a separate bounded grace instead of
       spending the live-input release lease before its first packet. */
    kNowPeekContinuityArmGraceTicks = 300,
    kNowPeekContinuityTickMs = 16
};

enum {
    kNowPeekContinuityTrackingPinHeldPoint = 1u << 0,
    kNowPeekContinuityTrackingVirtualGetMouse = 1u << 1,
    kNowPeekContinuityTrackingHideGuestCursor = 1u << 2,
    kNowPeekContinuityTrackingVirtualADB = 1u << 3,
    kNowPeekContinuityTrackingKnownMask =
        kNowPeekContinuityTrackingPinHeldPoint
            | kNowPeekContinuityTrackingVirtualGetMouse
            | kNowPeekContinuityTrackingHideGuestCursor
            | kNowPeekContinuityTrackingVirtualADB
};

enum {
    kNowPeekContinuityTraceServiceEnter = 1,
    kNowPeekContinuityTraceControl = 2,
    kNowPeekContinuityTraceRequest = 3,
    kNowPeekContinuityTraceApplied = 4,
    kNowPeekContinuityTraceApplyError = 5,
    kNowPeekContinuityTraceExit = 6,
    kNowPeekContinuityTraceReentry = 7,
    kNowPeekContinuityTraceCapacity = 8
};

/* Resident-only, allocation-free flight recorder. `seq` commits an entry
   last. The PPC application drains it only after the synchronous resident
   service returns, then serializes it through the normal task-time logger. */
typedef struct {
    NowPeekU32 seq;
    NowPeekU32 event;
    NowPeekU32 ticks;
    NowPeekI32 arg0;
    NowPeekI32 arg1;
} NowPeekContinuityTraceEntry;

enum {
    kNowPeekADBObserverUnavailable = 0,
    kNowPeekADBObserverInstalled = 1,
    kNowPeekADBObserverRecording = 2,
    kNowPeekADBObserverConflict = 3,
    kNowPeekADBObserverInstallFailed = 4,
    kNowPeekADBTraceCapacity = 8
};

/* V6's interrupt-owned ADB flight recorder. The service shim snapshots the
   three cursor globals before and after the incumbent relative-device handler
   and commits `seq` last. `data_0_3` and `data_4_7` preserve all eight bytes
   after the ADB Manager's Pascal length byte in wire order. */
typedef struct {
    NowPeekU32 seq;
    NowPeekU32 epoch;
    NowPeekU32 ticks;
    NowPeekU32 command;
    NowPeekU32 data_length;
    NowPeekU32 data_0_3;
    NowPeekU32 data_4_7;
    NowPeekI32 before_mouse_h;
    NowPeekI32 before_mouse_v;
    NowPeekI32 before_raw_h;
    NowPeekI32 before_raw_v;
    NowPeekI32 before_temp_h;
    NowPeekI32 before_temp_v;
    NowPeekU32 before_button;
    NowPeekI32 after_mouse_h;
    NowPeekI32 after_mouse_v;
    NowPeekI32 after_raw_h;
    NowPeekI32 after_raw_v;
    NowPeekI32 after_temp_h;
    NowPeekI32 after_temp_v;
    NowPeekU32 after_button;
} NowPeekADBTraceEntry;

/* P9. One app-owned latest-state mailbox and one resident-owned status
   block. The application commits control_seq and packet_seq LAST; the
   resident commits status_seq odd/even around its half. Every field is
   four bytes so the PPC and 68K compilers cannot disagree about padding. */
typedef struct {
    /* ---- written by the APPLICATION -------------------------------- */
    NowPeekU32 control_seq;
    NowPeekU32 enabled;
    NowPeekU32 epoch;
    NowPeekU32 lease_ticks;
    NowPeekU32 requested_hz;
    NowPeekU32 packet_seq;
    NowPeekU32 packet_epoch;
    NowPeekU32 position_seq;
    NowPeekI32 want_h;
    NowPeekI32 want_v;
    NowPeekU32 button_generation;
    NowPeekU32 flags;
    NowPeekU32 arrival_ticks;

    /* ---- written by the RESIDENT ----------------------------------- */
    NowPeekU32 status_seq;
    NowPeekU32 state;
    NowPeekU32 observed_control_seq;
    NowPeekU32 observed_packet_seq;
    NowPeekU32 applied_position_seq;
    NowPeekU32 applied_button_generation;
    NowPeekI32 at_h;
    NowPeekI32 at_v;
    NowPeekU32 last_arrival_ticks;
    NowPeekU32 apply_ticks;
    NowPeekU32 exit_reason;
    NowPeekU32 accepted_packets;
    NowPeekU32 stale_packets;
    NowPeekU32 timer_ticks;
    NowPeekU32 local_takeovers;
    NowPeekU32 button_down;
    NowPeekU32 accepted_hz;
    /* Safety telemetry. These distinguish a lease/reset that recovered from
       an Event Manager failure from a clean pointer-only session. */
    NowPeekU32 tasktime_cursor_applies;
    NowPeekU32 forced_resets;
    NowPeekU32 event_down_posts;
    NowPeekU32 event_up_posts;
    NowPeekU32 event_post_failures;
    NowPeekU32 event_reset_generation;
    /* Native takeover/reset diagnostics. Appended because this cell is the
       table tail; every preceding resident offset remains stable. */
    NowPeekU32 native_input_samples;
    NowPeekU32 native_input_changes;
    NowPeekU32 native_input_trigger;
    NowPeekI32 native_input_h;
    NowPeekI32 native_input_v;
    NowPeekI32 native_owned_h;
    NowPeekI32 native_owned_v;
    NowPeekU32 native_buttons;
    NowPeekU32 native_physical_valid;
    NowPeekU32 native_owned_valid;
    NowPeekU32 cursor_debt_cancels;
    /* V2 resident-owned tail. `service_proc` is a raw, relocated 68K code
       address, not a UPP and never called as a PPC function pointer. The app
       wraps it in a kM68kISA|kOld68kRTA RoutineDescriptor and reaches it only
       with CallUniversalProc from cooperative task time. Stable for the boot. */
    NowPeekU32 service_proc;
    NowPeekU32 service_calls;
    /* V3 application result. `apply_result_seq` commits `apply_result_err`
       last, after CursorDevicesGlue returns to the PPC task-time caller. */
    NowPeekU32 apply_result_seq;
    NowPeekI32 apply_result_err;
    /* V3 resident request. The application snapshots these only after the
       synchronous service returns and confirms the active state. */
    NowPeekU32 request_position_seq;
    NowPeekI32 request_h;
    NowPeekI32 request_v;
    NowPeekU32 service_reentries;
    NowPeekU32 trace_write_seq;
    NowPeekContinuityTraceEntry trace[kNowPeekContinuityTraceCapacity];
    /* V4 button transition tail. The resident requests one task-time Cursor
       Device transition and the PPC application commits its result. A timer
       may make MBState up first; pending_mouseup keeps the later manager debt
       explicit. The event_* names are retained because this table is
       accretive; they do not mean Event Manager calls in V4. */
    NowPeekU32 event_request_generation;
    NowPeekU32 event_request_down;
    NowPeekU32 event_result_generation;
    NowPeekU32 event_result_down;
    NowPeekI32 event_result_err;
    NowPeekU32 pending_mouseup;
    NowPeekU32 button_timer_ticks;
    NowPeekU32 button_forced_releases;
    NowPeekU32 button_release_reason;
    /* V5 experimental tracking tail. Written before control_seq commits, then
       read as immutable for the epoch. The two counters distinguish which
       intervention actually ran on metal. */
    NowPeekU32 tracking_options;
    NowPeekU32 tracking_pin_writes;
    NowPeekU32 tracking_getmouse_answers;
    /* V6 passive ADB observer tail. Installation happens only from the PPC
       application's synchronous resident service. The callback itself owns
       only these preallocated counters and ring entries. */
    NowPeekU32 adb_observer_state;
    NowPeekI32 adb_observer_address;
    NowPeekI32 adb_observer_handler_id;
    NowPeekU32 adb_observer_device_count;
    NowPeekI32 adb_observer_install_result;
    NowPeekU32 adb_observer_installs;
    NowPeekU32 adb_observer_callbacks;
    NowPeekU32 adb_observer_reentries;
    NowPeekU32 adb_observer_epoch;
    NowPeekU32 adb_trace_write_seq;
    NowPeekADBTraceEntry adb_trace[kNowPeekADBTraceCapacity];
    /* V7 active ADB substitution diagnostics. The experiment accepts only
       tiny carrier packets; larger physical deltas remain native. */
    NowPeekU32 adb_injection_packets;
    NowPeekU32 adb_injection_carriers;
    NowPeekU32 adb_injection_physical;
    NowPeekU32 adb_injection_clamps;
} NowPeekContinuityCell;

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

/* P6 liveness. Where the resident dials, and the shape is deliberately
   the dumbest one that works.
   ------------------------------------------------------------------
   IPv4 as four bytes in one word rather than a string, because parsing
   dotted-quad text at interrupt time is code this component must not
   have; a name is worse still, since resolving it needs the very
   application that may be starved. The host NOW connects to is one this
   machine already reached, so its address is known and numeric by the
   time the application writes it here.

   `epoch` is the commit word and is written LAST. Zero means "nothing to
   dial" — an application that has never connected, or one that has
   stopped consenting — and the resident treats it as an instruction to
   stay off the wire, not as an old value worth retrying. */
enum {
    kNowPeekLivenessFormatNone = 0,
    kNowPeekLivenessFormatV1 = 1,
    /* V2 says `endpoint_os` at the table's tail is written too, and is
       therefore a claim about a DIFFERENT field than the cell this word
       sits beside. That is deliberate and it is the accretive rule doing
       its job: `NowPeekLivenessEndpoint` has a pinned 44-byte layout, so
       the string had to append at the tail, and a reader needs one word
       to tell "the application wrote an OS string" from "those bytes are
       still the zeroes the table was cleared with".

       It matters because of what the OS string is FOR: the host
       associates a resident channel with its application by fingerprint,
       and the fingerprint is name AND OS. A resident that dials without
       one is a channel the host cannot attach to anything, which is
       indistinguishable from no channel at all. */
    kNowPeekLivenessFormatV2 = 2
};

typedef struct {
    /* Big-endian a.b.c.d packed into one word; both sides are the same
       machine, so there is no byte order to negotiate. */
    NowPeekU32 host_ipv4;
    NowPeekU32 host_port;
    /* Bumped by the application whenever the address changes, and
       written after the two fields above. A resident that saw epoch N
       and now sees N+1 redials; one that sees 0 disconnects. */
    NowPeekU32 endpoint_epoch;
    /* What the machine calls itself on the wire, so the resident's own
       hello carries the SAME name its application does — that name is
       what associates the two connections on the host, and a resident
       inventing one would be a channel vouching for nobody. Pascal
       string, fixed width, never a pointer into the application's heap:
       this is read from a foreign context after that heap may be gone. */
    unsigned char guest_name[32];
} NowPeekLivenessEndpoint;

/* P2 semantic assist. The evidence and rejected alternatives behind this
   deliberately small operation set are in docs/p2-semantic-evidence.md.
   The records are fixed-size because this code runs from a system-wide event
   filter: no allocation, unbounded traversal, or caller-selected byte count
   is permitted. */
enum {
    kNowPeekSemanticFormatNone = 0,
    kNowPeekSemanticFormatV1 = 1,
    /* Same fixed cell layout; control-class records now carry a typed
       Control Manager kind and an optional bounded displayed value. */
    kNowPeekSemanticFormatV2 = 2,
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
    kNowPeekSemanticControlListBox = 1,
    kNowPeekSemanticControlStandard = kNowPeekSemanticControlListBox,
    kNowPeekSemanticControlResource = 2,
    kNowPeekSemanticControlCustom = 3,
    kNowPeekSemanticControlClock = 4,
    kNowPeekSemanticControlGroupBox = 5,
    kNowPeekSemanticControlEditText = 6,
    kNowPeekSemanticControlStaticText = 7,
    kNowPeekSemanticControlWindowHeader = 8,
    kNowPeekSemanticControlPushButton = 9,
    kNowPeekSemanticControlCheckBox = 10,
    kNowPeekSemanticControlRadioButton = 11,
    kNowPeekSemanticControlPopupButton = 12,
    kNowPeekSemanticControlScrollBar = 13,
    kNowPeekSemanticControlDataBrowser = 14,
    kNowPeekSemanticControlUserPane = 15,
    kNowPeekSemanticControlImageWell = 16,
    kNowPeekSemanticControlOtherSystem = 17,
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

/* P2's SECOND cell: batched control classification.
   ------------------------------------------------------------------
   The cell above answers one question about one object. That is the
   right shape for a list or a menu - the answer is large and the
   question is rare - and the wrong shape for control classification,
   where the answer is 48 bytes and the question is asked of every
   control on the screen. A ten-panel corpus measured on 2026-08-05
   made the difference concrete: of 122 Control Manager controls,
   exactly ONE carried a determined kind. The classifier was never
   missing; it was starved by a transport that could ask about one
   control per scene and had to spend that one request on the list
   cells and menu rows that expire fastest.

   Classification is also the only P2 fact that is a PREREQUISITE for
   another: a list request cannot be made until a control is known to
   be a list box. Starving it stalls the plane behind it.

   Why a batch is not a bounds increase. Serving one class request
   already walks up to kSemanticWalkMax controls to prove the requested
   one is live and in the window, then discards the walk and classifies
   a single control. This cell keeps that one walk and classifies up to
   32 of the controls it already enumerated, so a 32-control window
   costs ONE walk instead of 32. The resolver's own bound - at most 32
   classifications and at most 32 copied text bytes each - is the bound
   already granted to the list-cell and menu-row resolvers in
   docs/p2-semantic-evidence.md. The per-fact cost falls; it does not
   rise.

   Why a second cell rather than a bigger one. `semantic` is not at the
   table's tail: act_v2 and event_block follow it, and the assert below
   pins act_v2 to semantic's end. Widening the record or the cell would
   move both and break an older reader silently - which is the reason
   act_v2 was itself appended rather than grown. So this is accretive,
   at the tail, gated by length plus its own format word. An older or
   shorter resident simply does not have it, and the application falls
   back to the single-control op with no loss of correctness. */
enum {
    kNowPeekSemanticBatchFormatNone = 0,
    kNowPeekSemanticBatchFormatV1 = 1,
    /* The ceiling on the resident's bounded control walk, and therefore
       the largest number of controls one window can ever report. It is
       stated HERE because three parties now depend on it: the resident
       bounds its walk array by it, the guard refuses a start ordinal at
       or beyond it, and the application stops paging at it. This is the
       limit that used to live only in the resident's own translation
       unit - the same shape as the control-frame cap that was fine until
       one of its three copies disagreed. */
    kNowPeekSemanticBatchWalkMax = 64
};

/* Same 48 bytes as NowPeekSemanticRecord, and deliberately NOT that
   type. A batched reply describes MANY controls, so every record has to
   name the one it describes. `control` is that name: the exact
   ControlRef the resident classified, echoed as evidence. It is never a
   walk ordinal - an ordinal would require both sides to derive the same
   traversal order and would attach a role to the wrong control, in
   silence, the day they diverged. */
typedef struct {
    NowPeekU32 control;
    NowPeekU16 kind;
    NowPeekU16 status;
    NowPeekU32 flags;
    NowPeekU16 text_length;
    NowPeekU16 text_copied;
    unsigned char text[kNowPeekSemanticTextMax];
} NowPeekSemanticClassRecord;

/* Same request/reply discipline as the cell above, and the same reader
   rule: copy only between two equal even generation reads, then recheck
   every echoed identity. The request names a WINDOW rather than an
   object, because the batch's subject is the window's control
   hierarchy. `request_start` is the 0-based walk ordinal to resume
   from, so a window with more controls than fit in one reply is drained
   by successive requests instead of truncated forever;
   response_total_count reports how many the walk found in all. */
typedef struct {
    NowPeekU32 request_generation;
    NowPeekU32 request_writer_epoch;
    NowPeekU32 request_target_a5;
    NowPeekU32 request_scene_generation;
    NowPeekU32 request_window;
    NowPeekU32 request_start;
    NowPeekU32 request_deadline_ticks;

    NowPeekU32 response_generation;
    NowPeekU32 response_request_generation;
    NowPeekU32 response_status;
    NowPeekU32 response_writer_epoch;
    NowPeekU32 response_target_a5;
    NowPeekU32 response_scene_generation;
    NowPeekU32 response_window;
    NowPeekU32 response_start;
    NowPeekU32 response_served_ticks;
    NowPeekU16 response_record_count;
    NowPeekU16 response_total_count;
    NowPeekSemanticClassRecord records[kNowPeekSemanticMaxRecords];
} NowPeekSemanticBatchCell;

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
    NowPeekU16 ext_minor;     /* release sequence; informational */
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
    /* U6 P5 append. One word, for the reason `content_block` is one: the
       ring lives in the system heap so it is not a ring every reader of
       every other plane carries past. 0 means the plane is absent, which
       is what an older resident reports simply by being shorter. */
    NowPeekU32 event_block;
    /* U7 P2 append. The second P2 cell, not a second plane: it is armed
       by kNowPeekTableCapTree like the first and gated by length plus
       the format word beside it. A resident that predates it is shorter
       and says so by being shorter. */
    NowPeekU16 semantic_batch_format;
    NowPeekU16 semantic_batch_length;
    NowPeekSemanticBatchCell semantic_batch;
    /* U8 P6 append. Where the resident should dial, written by the
       APPLICATION — the second field it owns, after arm_request, and for
       the same reason: only the application knows it. The host's address
       comes from preferences a person set, and the resident has no
       preferences, no file access at interrupt time and no way to ask.
       Without this the liveness channel cannot exist at all.

       Written whole and committed by `endpoint_epoch` LAST, which is the
       publish-last rule the writer lease already uses: a resident that
       reads a nonzero epoch has the whole address, and one that reads
       zero has no business dialling. The resident never writes here. */
    NowPeekU16 endpoint_format;
    NowPeekU16 endpoint_length;
    NowPeekLivenessEndpoint endpoint;
    /* **Proof the interrupt-time vehicle runs**, written by the resident
       and by nothing else. The Time Manager task bumps it on every tick,
       so an application that reads it before and after a starvation can
       say whether anything on this machine kept running while no
       application did — which is the premise the whole plane rests on,
       made checkable rather than argued.

       It is deliberately a COUNT and not a timestamp: a stopped clock
       and a stopped task look identical in a timestamp, and this must be
       able to distinguish them. */
    NowPeekU32 liveness_ticks;
    /* U9 P6 append. **Whether a transport is REACHABLE from this
       component at all**, written by the resident and by nothing else.

       It exists because the last transport question was answered by the
       linker rather than by a machine, and cost four library
       combinations to ask: Open Transport's 68K libraries are CFM/Shared
       Library Manager fragments and this extension is a flat 68K code
       resource, so they do not link. MacTCP's `.ipp` driver is the route
       left that keeps the resident an INIT, because the Device Manager
       is TRAPS — `PBOpen` and `PBControl` need no library at all.

       That claim deserves the same cheap refutation the OT one got, and
       this field is it: open the driver, record what happened, and dial
       nothing at all. A route that cannot be opened is dead before a
       single frame is framed, and finding that out costs one boot rather
       than a transport.

       `transport_result` carries the driver's own OSErr, so a refusal
       arrives with its reason attached rather than as a bare false. The
       difference between "no MacTCP on this machine" and "MacTCP said
       no" is the whole value of asking. */
    NowPeekU16 transport_format;
    NowPeekU16 transport_probe;
    NowPeekI32 transport_result;
    /* U10 P6 append. **The liveness channel itself**, which is the half
       U9's probe deliberately did not build: U9 opened a driver and
       dialled nothing, so that a route killed by the machine would cost
       one boot rather than a transport.
       ------------------------------------------------------------------
       `channel_state` is written by the RESIDENT and by nothing else, and
       it is a state rather than a boolean because the four ways this can
       be not-up are not one fact. A machine with no MacTCP, an
       application that has published no endpoint, a dial that was refused
       and a connection that dropped are four different things to tell a
       person, and a single `false` would make them one.

       `channel_result` carries the last OSErr the transport gave, so a
       failure arrives with its reason. `channel_sends` counts frames the
       resident put on the wire — the same kind of evidence
       `liveness_ticks` is, one plane further along: the vehicle proved it
       runs, and this proves it SPOKE.

       `endpoint_os` belongs to the application's endpoint publish above
       and is committed by the same `endpoint_epoch` write — it is here
       rather than inside the cell because that cell's layout is pinned by
       asserts a deployed resident depends on. `endpoint_format` == V2 is
       what says it was written. */
    NowPeekU16 channel_format;
    NowPeekU16 channel_state;
    NowPeekI32 channel_result;
    NowPeekU32 channel_sends;
    /* Pascal string, fixed width, never a pointer into the application's
       heap — read from a foreign context after that heap may be gone, for
       the same reason `guest_name` beside it is one. */
    unsigned char endpoint_os[32];
    /* U11 P7 append. **The drag session.** Appended at the tail by the
       accretive rule: every offset above is unchanged, and a resident or
       an application built before P7 finds each field exactly where it
       left it. `length` and `drag_format` together are what say this
       region was written — a reader must check BOTH, because a zeroed
       tail and an absent tail have to look different. */
    NowPeekU32 drag_format;   /* kNowPeekDragFormat* */
    NowPeekDragCell drag;
    /* U12 P8 append. **Where the drawn cursor was last put, and by
       which route.** Same accretive rule as the drag cell above it: a
       reader must check `length` AND `cursor_format`, because a zeroed
       tail and an absent tail have to look different. */
    NowPeekU32 cursor_format; /* kNowPeekCursorFormat* */
    NowPeekCursorCell cursor;
    /* U13 append. **What this resident is ACTUALLY doing right now**, as
       opposed to what it can do.
       ------------------------------------------------------------------
       `caps` answers "which planes does this binary have"; `arm_active`
       answers "which planes did the application ask for and get". Neither
       answers the question a person actually asks before installing a
       system extension: *with nothing running, what is still hooked?*

       Those are three different questions and this project has already
       paid for conflating two of them — a resident reported `active` with
       full capabilities while every act refused, and nothing named the
       cause, because a capability bit says what a binary CAN do and was
       being read as what it WAS doing.

       So this word reports installation, not intent, and it reports the
       things that PERSIST — including the ones that cannot be undone.
       `kNowPeekRestActPatched` is the sharpest of them: those six trap
       patches never come out (unpatching from the middle of a chain
       another extension may have joined is unsafe), so a machine that has
       once armed the act plane carries them until it reboots. That is a
       true fact about the machine and it should be visible, not inferred
       from a comment in a source file.

       Written by the resident and by nothing else. `gne_passes` is beside
       it because it is the denominator every other counter here needs: it
       is bumped on EVERY filter pass, armed or not, so "this counter is
       zero" can be told apart from "the filter never ran". Without it a
       resting machine and an uninstalled extension produce the same
       reading, which is precisely the negative this component must never
       report by accident. */
    NowPeekU16 rest_format;
    NowPeekU16 rest_state;
    NowPeekU32 gne_passes;
    /* U14 P9 append. The resident consumes only this bounded cell; the
       Open Transport endpoint and all datagram parsing remain in the PPC
       application, outside interrupt context. */
    NowPeekU32 continuity_format;
    NowPeekContinuityCell continuity;
} NowPeekTable;

/* What the resident currently HAS INSTALLED. A bitmask rather than a
   state, because these are independent facts and a machine can be in any
   combination of them; and installation rather than arming, because the
   two differ and the difference is the whole point of the word. */
enum {
    kNowPeekRestFormatV1 = 1
};
enum {
    /* The jGNE filter is chained. True on every booted machine carrying
       this extension and never false again — it is the one hook that
       cannot stand down, because it is what would notice a re-arm. It is
       reported anyway: "irreducible" is a claim a reader should be able
       to check rather than take. */
    kNowPeekRestGNEFilter     = 1u << 0,
    /* The Time Manager task is priming itself. FALSE on a machine whose
       application has never published an endpoint, and false again after
       one withdraws — the task retires by declining to re-prime rather
       than by being removed, so this bit going clear means the interrupt
       has genuinely stopped, not that it is idling. */
    kNowPeekRestLivenessTicking = 1u << 1,
    /* MacTCP's .IPP driver has been opened by US, and/or a TCP stream
       with its receive buffer exists. Never true until an application
       publishes an endpoint. */
    kNowPeekRestTransport     = 1u << 2,
    /* The content plane's ~64 KiB system-heap block is allocated. Held
       from boot for the life of the machine: arming happens inside a
       foreign process where allocation is illegal, so the block cannot
       be made lazy without moving the allocation to the first leased
       filter pass. See docs/resident-components.md. */
    kNowPeekRestContentBlock  = 1u << 3,
    /* At least one GrafPort currently carries our grafProcs. Goes clear
       when the owning context next pumps and gives them back. */
    kNowPeekRestContentHooks  = 1u << 4,
    /* The act plane's trap patches are in. **Never clears until the
       machine reboots** — see the field comment above. */
    kNowPeekRestActPatched    = 1u << 5,
    /* The NewGWorld trap patch (record mode) is in. Same one-way rule as
       the act patches, and for the same reason. */
    kNowPeekRestQDExtPatched  = 1u << 6,
    /* Continuity's GetMouse, StillDown, and Button chain hooks are in.
       Installed lazily on the first accepted Continuity arm and never
       removed until reboot; idle hooks perform only a byte test and tail
       jump to the incumbent. */
    kNowPeekRestCursorTrackingPatched = 1u << 7,
    /* A passive wrapper is installed around the relative ADB device's
       incumbent service routine. It remains pass-through until reboot even
       while recording is idle, because unlinking from an extended chain is
       unsafe. */
    kNowPeekRestADBObserverInstalled = 1u << 8
};

/* What the resident's own liveness channel is doing. Values are the
   contract and append rather than renumber. */
enum {
    kNowPeekChannelFormatV1 = 1
};
enum {
    /* Nothing is wrong and nothing is dialling: no endpoint published, or
       an epoch of 0, which is the application saying stay off the wire. */
    kNowPeekChannelIdle      = 0,
    kNowPeekChannelOpening   = 1,   /* TCPActiveOpen is in flight */
    kNowPeekChannelUp        = 2,   /* connected, and hello is sent */
    /* The dial or a send was refused; `channel_result` says by what. The
       resident backs off and tries again rather than latching, because
       the machine it dials may simply not be up yet. */
    kNowPeekChannelFailed    = 3,
    /* No transport at all — the driver never opened, or the stream could
       not be created. This one IS terminal for the boot. */
    kNowPeekChannelNoTransport = 4
};

/* What the resident found when it reached for a transport. The values
   are the contract and are never inferred from an ordering, so a later
   probe state appends rather than renumbers — the same rule the
   capability bits follow. */
enum {
    kNowPeekTransportFormatV1 = 1
};
enum {
    kNowPeekTransportUntried = 0,   /* nothing has looked yet */
    kNowPeekTransportOpen    = 1,   /* the .ipp driver opened */
    kNowPeekTransportRefused = 2    /* it answered, and said no */
};

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
/* The table ends where its last appended field ends. Every append edits
   this line, and that is the point: it is the one assert that notices a
   field added anywhere but the tail. */
/* Retired by U11: the endpoint OS string is no longer the tail. Kept as
   a fixed-position assert rather than deleted, because what a deployed
   resident depends on is the OFFSET, and that is what an append must not
   move. The "is the tail" claim belongs to whichever region appended
   last, and is asserted once, at the bottom of this file. */
_Static_assert(offsetof(NowPeekTable, endpoint_os)
                    + sizeof(((NowPeekTable *)0)->endpoint_os)
                   == offsetof(NowPeekTable, drag_format),
               "the endpoint OS string keeps its place under an append");
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

/* P2's second cell. The batch record is the same 48 bytes as the record
   above - one 32-bit control name in place of the index/aux pair - so a
   reader that knows one record's width is not surprised by the other's,
   and neither compiler pads either. The cell's header is 16 four-byte
   fields plus one 16-bit pair: 68, which is 4-aligned, so the record
   array starts clean. */
_Static_assert(sizeof(NowPeekSemanticClassRecord) == 48,
               "semantic class record size");
_Static_assert(offsetof(NowPeekSemanticClassRecord, text) == 16,
               "semantic class record text offset");
_Static_assert(offsetof(NowPeekSemanticBatchCell, records) == 68,
               "semantic batch records offset");
_Static_assert(sizeof(NowPeekSemanticBatchCell)
                   == 68 + 48 * kNowPeekSemanticMaxRecords,
               "semantic batch cell size");
/* The append is at the tail, after P5's one word - so every offset
   above, including act_v2's, is byte-for-byte what it was. */
_Static_assert(offsetof(NowPeekTable, semantic_batch_format)
                   == offsetof(NowPeekTable, event_block) + 4,
               "semantic batch append offset");
_Static_assert(offsetof(NowPeekTable, semantic_batch)
                   == offsetof(NowPeekTable, semantic_batch_format) + 4,
               "semantic batch cell offset");

_Static_assert(offsetof(NowPeekTable, event_block)
                   == offsetof(NowPeekTable, act_v2)
                       + sizeof(NowPeekActV2Cell),
               "event block appends after act_v2 without moving it");

/* P6's endpoint, appended at the tail after P2's batch cell, so every
   offset above is byte-for-byte what it was and a resident that predates
   this region says so simply by being shorter. */
_Static_assert(sizeof(NowPeekLivenessEndpoint) == 44,
               "liveness endpoint size");
_Static_assert(offsetof(NowPeekLivenessEndpoint, endpoint_epoch) == 8,
               "liveness epoch offset — the commit word, written LAST");
_Static_assert(offsetof(NowPeekLivenessEndpoint, guest_name) == 12,
               "liveness guest name offset");
_Static_assert(offsetof(NowPeekTable, endpoint_format)
                   == offsetof(NowPeekTable, semantic_batch)
                       + sizeof(NowPeekSemanticBatchCell),
               "liveness endpoint appends without moving P2's batch");
_Static_assert(offsetof(NowPeekTable, endpoint)
                   == offsetof(NowPeekTable, endpoint_format) + 4,
               "liveness endpoint cell offset");
_Static_assert(offsetof(NowPeekTable, liveness_ticks)
                   == offsetof(NowPeekTable, endpoint)
                    + sizeof(NowPeekLivenessEndpoint),
               "liveness tick counter is the tail");
/* U9's append, pinned the same way and for the same reason: the probe
   pair must sit immediately after the counter, or an application built
   against U8 and an extension built against U9 disagree about where the
   counter it DOES understand ends. */
_Static_assert(offsetof(NowPeekTable, transport_format)
                   == offsetof(NowPeekTable, liveness_ticks) + 4,
               "transport probe appends behind the tick counter");
_Static_assert(offsetof(NowPeekTable, transport_result)
                   == offsetof(NowPeekTable, transport_format) + 4,
               "transport result offset");
/* U10's append. Same shape and same reason as U9's: the channel block
   must sit immediately behind the probe pair, or an application built
   against U9 and an extension built against U10 disagree about where the
   field they BOTH understand ends. */
_Static_assert(offsetof(NowPeekTable, channel_format)
                   == offsetof(NowPeekTable, transport_result) + 4,
               "the liveness channel appends behind the transport probe");
_Static_assert(offsetof(NowPeekTable, channel_result)
                   == offsetof(NowPeekTable, channel_format) + 4,
               "channel result offset");
_Static_assert(offsetof(NowPeekTable, channel_sends)
                   == offsetof(NowPeekTable, channel_result) + 4,
               "channel send counter offset");
_Static_assert(offsetof(NowPeekTable, endpoint_os)
                   == offsetof(NowPeekTable, channel_sends) + 4,
               "the endpoint's OS string offset");
/* U11 P7. The drag cell appends behind the endpoint OS string, so every
   offset a deployed resident depends on is unchanged and these are
   the only new numbers. 25 four-byte fields, no padding under any of the
   three compilers - which is the layout rule stated at the top of this
   file, and these asserts are how it is watched rather than assumed.

   The width assert is not decoration. This struct is written by an
   INTERRUPT-TIME task in one binary and read by a Carbon application
   compiled by a different compiler; a packing difference here would show
   up as a drag that reads its own deadline out of somebody else's field,
   which is the one defect in this plane that ends with a machine holding
   the mouse button down. */
_Static_assert(sizeof(NowPeekDragCell) == 100, "drag cell size");
_Static_assert(offsetof(NowPeekDragCell, want_seq) == 24,
               "the want commit word's offset");
_Static_assert(offsetof(NowPeekDragCell, button_down) == 96,
               "the button state is the drag cell's tail");
_Static_assert(offsetof(NowPeekTable, drag_format)
                   == offsetof(NowPeekTable, endpoint_os) + 32,
               "the drag plane appends behind the endpoint OS string");
_Static_assert(offsetof(NowPeekTable, drag)
                   == offsetof(NowPeekTable, drag_format) + 4,
               "drag cell offset");
_Static_assert(sizeof(NowPeekCursorCell) == 40, "cursor cell size");
_Static_assert(offsetof(NowPeekCursorCell, yielded) == 28,
               "the yield counter's offset");
_Static_assert(offsetof(NowPeekTable, cursor_format)
                   == offsetof(NowPeekTable, drag) + sizeof(NowPeekDragCell),
               "the cursor plane appends behind the drag cell");
_Static_assert(offsetof(NowPeekTable, cursor)
                   == offsetof(NowPeekTable, cursor_format) + 4,
               "cursor cell offset");
/* U13's append. The rest-state pair and the pass counter sit behind the
   CURSOR cell, not behind the OS string: P7 and P8 appended first and a
   deployed resident depends on those offsets, so this region took the new
   tail rather than the place its own lane wrote it. Same accretive rule
   either way — an application built against U12 reads a SHORTER `length`
   and simply never looks here, which is the whole mechanism by which an
   old reader and a new resident stay honest with each other. */
_Static_assert(offsetof(NowPeekTable, rest_format)
                   == offsetof(NowPeekTable, cursor)
                          + sizeof(NowPeekCursorCell),
               "the rest-state pair appends behind the cursor cell");
_Static_assert(offsetof(NowPeekTable, gne_passes)
                   == offsetof(NowPeekTable, rest_format) + 4,
               "the filter pass counter follows the rest-state pair");
_Static_assert(sizeof(NowPeekContinuityTraceEntry) == 20,
               "continuity trace ABI drift");
_Static_assert(sizeof(NowPeekADBTraceEntry) == 84,
               "ADB observer trace ABI drift");
_Static_assert(sizeof(NowPeekContinuityCell) == 1160,
               "continuity cell size");
_Static_assert(offsetof(NowPeekContinuityCell, packet_seq) == 20,
               "continuity packet commit offset");
_Static_assert(offsetof(NowPeekContinuityCell, status_seq) == 52,
               "continuity resident half offset");
_Static_assert(offsetof(NowPeekContinuityCell, service_proc) == 188,
               "continuity V2 service offset");
_Static_assert(offsetof(NowPeekContinuityCell, apply_result_seq) == 196,
               "continuity V3 application result offset");
_Static_assert(offsetof(NowPeekContinuityCell, request_position_seq) == 204,
               "continuity V3 resident request offset");
_Static_assert(offsetof(NowPeekContinuityCell, trace) == 224,
               "continuity V3 trace offset");
_Static_assert(offsetof(NowPeekContinuityCell, event_request_generation) == 384,
               "continuity V4 button request offset");
_Static_assert(offsetof(NowPeekContinuityCell, pending_mouseup) == 404,
               "continuity V4 release debt offset");
_Static_assert(offsetof(NowPeekContinuityCell, button_release_reason) == 416,
               "continuity V4 release reason offset");
_Static_assert(offsetof(NowPeekContinuityCell, tracking_options) == 420,
               "continuity V5 tracking options offset");
_Static_assert(offsetof(NowPeekContinuityCell, tracking_pin_writes) == 424,
               "continuity V5 pin counter offset");
_Static_assert(offsetof(NowPeekContinuityCell, tracking_getmouse_answers) == 428,
               "continuity V5 GetMouse counter offset");
_Static_assert(offsetof(NowPeekContinuityCell, adb_observer_state) == 432,
               "continuity V6 ADB observer offset");
_Static_assert(offsetof(NowPeekContinuityCell, adb_trace) == 472,
               "continuity V6 ADB trace offset");
_Static_assert(offsetof(NowPeekContinuityCell, adb_injection_packets) == 1144,
               "continuity V7 ADB injection offset");
_Static_assert(offsetof(NowPeekTable, continuity_format)
                   == offsetof(NowPeekTable, gne_passes) + 4,
               "continuity appends behind the pass counter");
_Static_assert(offsetof(NowPeekTable, continuity)
                   == offsetof(NowPeekTable, continuity_format) + 4,
               "continuity cell offset");
_Static_assert(sizeof(NowPeekTable)
                   == offsetof(NowPeekTable, continuity)
                          + sizeof(NowPeekContinuityCell),
               "the continuity cell is the new tail");

#endif /* NOW_PEEK_TABLE_H */
