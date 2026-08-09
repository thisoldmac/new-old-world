#ifndef NOW_SCENE_H
#define NOW_SCENE_H

/* For NowSceneSpans, which now_scene_encode_spans fills. The delta plane
   is a separate header on purpose - it is pure arithmetic over an
   encoded document and knows nothing about a NowScene. */
#include "scene_digest.h"

/* For NowDesktopFacts, which meta.desktop carries. The struct is declared
   above that header's Toolbox guard on purpose, so this header stays
   compilable by the host cc for the native tests - and so the desktop
   answer is ONE struct, gathered once, served to both the `desktop`
   command and to every scene, rather than two producers of the same
   fact drifting apart. */
#include "desktop.h"

/* The scene envelope: NOW's guest producing Mirror's frozen v1 scene IR
   over the part of the machine it can honestly walk today.
   (archive/mirror-standalone-2026-08-09/docs/IR-V1.md; docs/scene-producer.md for what is and is not
   produced, and why.)

   THE PRODUCED SUBSET is `version` / `seq` / `capturedAt` / `source`,
   `screen.{w,h}`, `apps[].{psn,name,front,error}`,
   `processes[].{psn,name,front,signature}`,
   `windows[].{id,app,psn,title,rect,front,z,visible}` and `meta`, plus
   the four planes the foreign-memory walk added on 2026-07-31:
   `menubar.{app,menus[]}`, `windows[].controls[]`, `windows[].text` and
   `windows[].kind`.

   THE FOUR NEW PLANES ARE CONDITIONAL, WHICH IS NOT THE SAME AS
   PRODUCED. Each is emitted for exactly the rows whose walk actually
   ran and completed, and omitted everywhere else - so `controls` absent
   on one window and `[]` on another are two different, both-true
   statements about the same scene. `kind` needs the window record to
   have validated; `controls` needs its whole chain walked to the end;
   `text` needs a Dialog Manager window with a TextEdit record; `menubar`
   needs the FRONT process to have bound and its menu list to have
   parsed. NOW's own process never contributes any of them, because NOW
   is Carbon and its records are not at these classic offsets
   (axprocess.h says the same thing about the walk it belongs to).

   THE REFERENCE PLANE, added 2026-08-01, is the fifth conditional one
   and the one that makes a scene ACTABLE. `windows[].ref` and
   `controls[].ref` carry a token minted by the observation registry
   (src/observe/), resolvable by now_observe_resolve_window /
   now_observe_resolve_element - so a control a renderer drew can be
   named back to this guest. Without it the scene drew buttons whose
   `ref` was empty, and every act against one was refused as
   "needs observation": chrome, titles, menus and controls all rendered,
   and nothing was clickable.

   IT IS CONDITIONAL LIKE THE OTHERS AND FOR A SHARPER REASON. A
   reference is minted only for an element a resolution could actually
   reach, and the registry holds a bounded number of them. When the walk
   cannot name an element - past the resolver's own chain bounds, off the
   chain, or the registry has no slot left for this scene - the key is
   ABSENT. Absent means NOT MINTED, which is true; an empty string would
   mean "the producer has no reference layer", which is a different and
   false claim (the host's own adapter already reads `ref: ""` that way).
   Nothing here invents, shortens or re-derives a token: this plane is a
   copy of what src/observe/obsmint.c handed over, or it is missing.

   `windows[].ref` is an ADDITION to IR v1's window field set (which
   lists id/app/psn/title/rect/front/z/visible/kind/controls/text), taken
   under the accretive rule: additive fields do not move the version
   number. `controls[].ref` is not an addition at all - IR v1 promotes
   `windows[].controls[].*` - it is a declared field this producer had
   been leaving empty.

   EVERYTHING ELSE IS AN ABSENT KEY, NOT AN EMPTY ONE.
   `windows[].display[]`, `windows[].items[]`, `desktopItems[]`,
   `controls[].checked`, `menus[].apple` and `meta.bytes` are omitted,
   because an empty array asserts "this window has no controls" and
   absence says "this producer does not report controls". IR v2 keeps a
   structurally required legacy `role` on every Control row, but records
   an unproven kind as `unknown` and denies it an action in `semantic`.
   Those are different claims and the difference is the point.

   A TRUNCATION THAT CANNOT BE ATTRIBUTED IS RETRACTED, NOT REPORTED
   SHORT. `meta.errors` carries one line per truncation, which is enough
   for the scene-wide arrays (`processes`, `windows`, `menus`) because
   there is only one of each to be short. A window's `controls` and a
   menu's `items` have no such marker beside them, so a short one would
   read as a complete one; when either hits a bound or a refusal
   mid-chain the whole sub-plane is DROPPED for that owner - the key
   goes absent, and `meta.errors` says a bound was hit. Absence is a
   claim this producer can make honestly; a list that stops early is
   not.

   THE VERSION IS STAMPED ONCE. NOW_SCENE_IR_VERSION is the body's
   `version` and is the same number any serving layer must copy into the
   result's `irVersion` key - one constant, so the envelope key and the
   body stamp cannot diverge without editing this line. That is
   upstream's rule (IR-V1.md, "One number, two places") and the same
   accretive rule contract/peek_table.h already applies to the in-memory
   seam: additive fields do not move the number; removing or renaming
   one does.

   TOOLBOX-FREE ON PURPOSE, like peek_oracle.c and for the same reason:
   assembly takes its inputs as arguments - process rows, window rows,
   verdicts, a clock - so every rule below is reachable from a native
   test on the host with no Macintosh in the loop. The impure half (ask
   the Process Manager, walk the anchor plane) is scene_collect.c. */

#include "scene_anchor.h"

#define NOW_SCENE_IR_VERSION 2

enum {
    kNowSceneMaxProcs = 40,       /* process rows carried per scene */
    kNowSceneMaxWindows = 64,     /* window rows carried per scene */
    kNowSceneNameMax = 32,        /* process name, MacRoman */
    kNowSceneTitleMax = 48,       /* window title, MacRoman */
    kNowSceneSourceMax = 16,
    kNowScenePlaneMax = 64,
    kNowSceneIdMax = kNowSceneNameMax + kNowSceneTitleMax + 16,

    /* Kept as layout vocabulary for code that measures Platinum chrome.
       It is deliberately NOT enough to infer a control kind: a custom
       control can have the same thickness. */
    kNowScrollBarThickness = 16,

    /* THE TITLE BAR THE IR'S TWO RECTANGLES ARE RELATED BY, AND THE ONE
     * PLACE ANY WINDOW RECT IS DERIVED.
     *
     * IR v1's `windows[].rect` is a BOX: the content region grown upward
     * by this much. Mirror's own producer constructs it that way, and its
     * consumer takes it apart the same way - MirrorKit's hit tester finds
     * the content origin at `rect.t + titleBarHeight` before it compares
     * a click against a control's content-relative rect.
     *
     * So this is a CONVENTION shared with the consumer, not a measurement
     * of any particular window's frame. Reporting the true structure
     * region instead would be more honest about this Macintosh and would
     * break the arithmetic on the other side, which is the wrong trade:
     * the number's job is to let a consumer recover the content origin
     * exactly. `windows[].rect` is a JOIN KEY between two sides that
     * decompose it the same way, and a join key's value is that both
     * sides spell it identically.
     *
     * Measured on a live Finder, 2026-08-02, before this existed: NOW
     * emitted the content region here, so a real hardware click at the
     * point a renderer computes from the document landed twenty pixels
     * below the scroll arrow and the machine did not move. Clicking
     * twenty pixels higher moved it (-4 to 60). The document was wrong
     * and both of its own gates agreed with it.
     *
     * WHAT CHANGED 2026-08-07. That convention was applied on ONE of the
     * three branches that add a window. A bound foreign process went
     * through it; an unbound one published peek_read's STRUCTURE region
     * raw, and NOW's own windows published Carbon's structure region -
     * so one field carried three meanings in one document, and which one
     * a row held depended on whether a bind had happened. That is the
     * surface answering one question three ways, and a consumer had no
     * way to ask which it was holding.
     *
     * Both foreign readers now return BOTH regions from the machine
     * (peek_read.h, axwalk.h), so every branch adds a window as
     * `content grown up by this constant` and there is one derivation.
     * The constant is still an approximation of a real title bar - they
     * are not one height across window kinds and the Appearance Manager
     * draws them procedurally - but it is now an approximation of ONE
     * thing in ONE place, checkable against the structure region the
     * same walk read, instead of a third answer competing with two
     * measurements. Publishing the true region under `rect` needs the
     * consumer to change with it and an IR version to carry it; it is
     * not something one side may do alone. */
    kNowSceneIRTitleBarHeight = 20,

    /* The walk's caps. Each is a BOUND on a scene, not a belief about a
       machine, and each one reports itself when it bites (see the
       retraction rule above). The pools are shared across owners rather
       than sized per owner, because a desktop's controls are not spread
       evenly - one dialog can hold thirty and twenty windows hold none -
       and a per-window array of thirty would cost 64 x 30 entries to
       serve the same scene.

       The scene struct they size is heap-resident and deliberately bounded
       (larger than the earlier ~27 KB after structured list cells were added;
       a little smaller on the guest, where `long` is 32-bit), up from ~11 KB
       before the walk. It is heap-allocated by its caller for that
       reason - a classic Mac stack is 24-32 KB - and a caller that
       cannot get the block says so rather than walking a smaller
       machine. */
    kNowSceneMaxMenus = 16,       /* menus in the one menu bar */
    kNowSceneMaxMenuItems = 96,   /* menu items, pooled across menus */
    kNowSceneMaxControls = 96,    /* controls, pooled across windows */
    kNowSceneMaxDialogItems = 96, /* Dialog Manager items, separately */
    kNowSceneMaxListCells = 256,  /* bounded P2 cells across list controls */
    kNowSceneMaxTexts = 4,        /* windows carrying TextEdit content */
    kNowSceneMenuTitleMax = 32,
    kNowSceneItemTitleMax = 40,
    kNowSceneCtlTitleMax = 32,
    /* Dialog text is human-facing state, not a compact control label. The
       previous 31-character payload cut "Set Daylight-Saving Time
       Automatically" mid-word in the Mirror while the guest showed it in
       full. This matches the encoder's existing longest-string bound. */
    kNowSceneDialogTitleMax = 160,
    /* Deliberately short. It bounds the encoder's escape buffer (a
       MacRoman byte can become six of `\uXXXX`), which lives on the
       stack of a leaf function called from the event loop; a dialog's
       editable text is a filename or a field, and anything longer is
       reported truncated rather than carried. */
    kNowSceneTextMax = 160,

    /* An observation reference as it appears on the wire:
       "now-element-" plus a 36-character UUID layout, plus the
       terminator, rounded up. It is deliberately the same number as
       kNowObsTokenMax and is NOT that constant: obsref.h would drag the
       reference layer into every consumer of this header, including the
       host tests that exist because assembly is Toolbox-free. The two
       are pinned against each other at compile time in scene_walk.c,
       which is the one file that sees both - the same trick
       scene_collect.c uses for the anchor verdicts, and for the same
       reason: a silently shortened reference would be a token that
       looks well formed and resolves to nothing. */
    kNowSceneRefMax = 56
};

typedef struct {
    long hi;                      /* ProcessSerialNumber.highLongOfPSN */
    unsigned long lo;
} NowScenePsn;

typedef struct {
    short t, l, b, r;
} NowSceneRect;

/* Collection-level authority for IR v2. Only COMPLETE permits a consumer
   to remove previously observed members that are absent from this scene.
   The other values preserve distinct failure modes instead of collapsing
   them into an empty array. */
typedef enum {
    kNowSceneCoverageUnavailable = 0,
    kNowSceneCoverageComplete = 1,
    kNowSceneCoveragePartial = 2,
    kNowSceneCoverageRetracted = 3,
    kNowSceneCoverageFailed = 4,
    kNowSceneCoverageStale = 5
} NowSceneCoverage;

typedef struct {
    NowScenePsn psn;
    char name[kNowSceneNameMax];
    unsigned long signature;      /* creator OSType; 0 = unknown */
    unsigned long incarnation;    /* process fingerprint; 0 = unknown */
    int front;                    /* the frontmost process */
    NowSceneAnchor anchor;        /* the verdict for this partition */
    unsigned long stamp_ticks;    /* the anchor's capture tick */
    int stale;                    /* Ok, but older than the caller's window */
    /* THE PROCESS'S OWN DECLARATION that it has no user interface: the
       `modeOnlyBackground` bit of its 'SIZE' resource, as the Process
       Manager reports it in ProcessInfoRec.processMode. A faceless
       background application - Control Strip Extension, Folder Actions,
       an 'appe' worker - sets it, and for such a process having no
       windows is a NORMAL, EXPECTED state rather than an unobserved one.
       "Headless" and "faceless" are the same fact in prose; the wire
       word is `backgroundOnly` everywhere, matching the OS bit, and
       ProcessListing's `kind: "background"` is the enum spelling of the
       same declaration.

       THE APPLICATION MENU IS NOT A SECOND SIGNAL. Its membership is
       this same bit, one remove away: the Process Manager omits a
       `modeOnlyBackground` application from the Application menu, which
       is why the mirror's own SYNTHESISED switcher listing background
       processes read as wrong beside the real one (open-issues,
       Cycle 20). Reading that menu back to learn what a process IS would
       put a walked UI artifact in the path of a fact the Process Manager
       hands over directly - and would fail for the very processes it is
       asked about. There is one source here, and it is this field.

       Never inferred from an empty window list. That inference cannot
       tell "has no UI by design" from "we failed to look", and asserting
       the first from the second is what made six healthy processes read
       as `ax_oracle_not_found` errors on a good boot. 0 means the
       process did not declare it - not that we know it has a face. */
    int background_only;
    short window_count;           /* windows admitted for this process */
    NowSceneCoverage windows_coverage;
} NowSceneProc;

/* One control, already in GLOBAL coordinates: axwalk translates a
   control's local rect by its window's content origin, so a consumer
   never has to know the local frame.

   `checked` is NOT here and is not emitted, because it is meaningless
   without knowing WHICH kind of control this is, and a walk of a foreign
   ControlRecord cannot say. Inventing a role from a value range would be
   exactly the guess the absent-key rule exists to prevent - and was the
   2026-08-03 defect that drew Mail's alert buttons as scroll bars.

   `role` IS here: empty for a foreign control until the resident's
   semantic plane names one, and procID-derived for a control this
   application made itself (scene_self.c).

   As of 2026-08-05 the walk DOES read contrlDefProc - see `definition`
   below - but that answers a strictly weaker question, which heap the
   definition function came from, and never becomes a role.

   `ref` IS here, as of 2026-08-01, and an empty one is an absent key
   rather than an empty string on the wire. It is a copy of a token the
   observation registry minted for this exact control; nothing in this
   file makes one, shortens one, or can tell whether one is valid. */
typedef struct {
    char title[kNowSceneCtlTitleMax];
    NowSceneRect rect;
    int enabled;                  /* contrlHilite != 255 */
    int visible;
    short value, min, max;
    char ref[kNowSceneRefMax];    /* "" = not minted, key stays absent */
    /* What KIND of control this is, when something could actually say.
       Empty means nobody could, and the emitter reports unknown with no
       action. A walk of a foreign ControlRecord still cannot tell button
       from checkbox; an application asking the Control Manager about its
       OWN control can, and does. */
    char role[16];
    /* WHERE the control's definition came from, when the role is still
       empty. A `NowAxDefProcOrigin`, and deliberately NOT a kind: it
       separates a definition the Toolbox supplied from one the
       application supplied, which is the split that decides whether a
       documented answer exists to go looking for. Zero (Absent) is the
       nothing-to-say value, and self-observed controls leave it there -
       they already have a procID-derived role, which is strictly more. */
    short definition;
    /* WHICH definition function, when the Resource Manager could name it
       - a `NowCdefState` and, for `Named`, the `CDEF` resource id and the
       variation code the machine confirmed. This is one step stronger
       than `definition` (which heap) and one step weaker than `role`
       (what the control itself said it is), and it must stay in the
       middle: the emitter reports it under its own knowledge level, and
       nothing here promotes it. Zero (`Unattempted`) is the
       nothing-to-say value. */
    short cdef_state;
    short cdef_id;
    short cdef_variant;
    int semantic_value_known;
    char semantic_value[kNowSceneTextMax];
    int list_cells_present;
    short first_list_cell;
    short list_cell_count;
    unsigned short list_total_count;
    int list_cells_complete;
    unsigned long handle;         /* internal join to a DITL item */
} NowSceneControl;

/* A window's TextEdit content. `truncated` is true when the TERec's own
   length exceeded what is carried, so a consumer says "truncated" rather
   than presenting a prefix as the whole text. */
typedef struct {
    char content[kNowSceneTextMax];
    int active;
    int truncated;
    short selection_start;
    short selection_end;
} NowSceneText;

/* One guest-provided semantic list cell. Row is 1-based to match List
   Manager presentation and column is 0-based to match Cell.h. */
typedef struct {
    short row;
    short column;
    int selected;
    char text[kNowSceneTextMax];
} NowSceneListCell;

enum {
    kNowSceneSemanticUnknown = 0,
    kNowSceneSemanticPushButton = 1,
    kNowSceneSemanticCheckBox = 2,
    kNowSceneSemanticRadioButton = 3,
    kNowSceneSemanticPopupMenu = 4,
    kNowSceneSemanticStaticText = 5,
    kNowSceneSemanticEditText = 6,
    kNowSceneSemanticIcon = 7,
    kNowSceneSemanticPicture = 8,
    kNowSceneSemanticUserItem = 9,
    kNowSceneSemanticPanel = 10,
    kNowSceneSemanticPlacard = 11,
    kNowSceneSemanticSelectionBand = 12,
    kNowSceneSemanticSeparator = 13
};

/* A window's walk verdict. Only the ones a reader can act on differently
   are separate values: "the record would not validate" sends someone to
   the anchor plane, "the control chain broke" sends them to the control
   walk, and they are not the same errand. */
enum {
    kNowSceneWalkOk = 0,
    kNowSceneWalkRecordUnreadable = 1,  /* the WindowRecord failed validation */
    kNowSceneWalkControlsRetracted = 2, /* the chain broke or hit its bound */
    kNowSceneWalkDialogItemsRetracted = 3,
    kNowSceneWalkControlsAndItemsRetracted = 4,
    /* The two causes of a control retraction, kept apart because they
       are different errands: a chain longer than the scene carries is
       OUR bound, and a chain that failed validation is the machine
       being unreadable where we looked. Lumping them sends whoever
       reads the note to raise a cap that was never the problem. */
    kNowSceneWalkControlsBound = 5,
    kNowSceneWalkControlsInvalid = 6,
    /* A third cause, split off for the same reason the first two were:
       a chain that does not terminate within the diagnostic probe bound
       is cyclic or corrupt, and no cap raise reaches it. Reported as
       "bound" it would argue forever for a bigger number. */
    kNowSceneWalkControlsCyclic = 7,
    /* A FOURTH cause, and the only one that is not about this window.
     *
       The control pool is shared across every window in the scene. A
       window walked after it filled calls now_scene_add_control, is
       refused for want of a SLOT, and retracts - so a panel with twenty
       controls reported `controls: []` for a reason that had nothing to
       do with that panel, and read on the wire exactly like a window
       proven to have none.
     *
       That is the empty/unknown conflation with a third face on it: we
       did not look at this window's controls, and we could have. It is
       kept apart from Bound (this window's OWN chain is longer than we
       carry), from Invalid (the machine was unreadable) and from Cyclic
       (no cap raise reaches it) because those three are answers about
       the machine and this one is an answer about us - and it is the
       only one a consumer could fix by asking again. */
    kNowSceneWalkControlsPoolFull = 8
};

/* WHAT IS KNOWN ABOUT A WINDOW'S CONTROLS, as one word.
 *
 * `controls: []` has carried three different facts since the plane was
 * written, and the IR requires the key, so absence could not be used to
 * separate them. The verdict above says why a plane was dropped, in
 * prose, in meta.errors - readable by a person and by nothing else.
 * This is the same knowledge as a value a consumer can branch on:
 *
 *   complete    walked, and here they are
 *   empty       walked, and this window has none. A fact about the
 *               MACHINE, and the only one of the four that licenses a
 *               renderer to draw a bare window.
 *   unknown     we looked and could not establish it - the chain was
 *               longer than we carry, or failed validation, or did not
 *               terminate. A fact about the machine being unreadable
 *               where we are allowed to look.
 *   notFetched  we have not asked. The pool was spent on other windows,
 *               or this producer never opened the plane for this window
 *               at all. A fact about US, and the only one of the four
 *               that could be answered by asking again.
 *
 * A window whose RECORD would not validate is `unknown`, not
 * `notFetched`: we did try, and the machine was unreadable where we are
 * allowed to look. The line between the two words is not how much work
 * was done, it is whose fault the silence is.
 *
 * Deriving `unknown` and `notFetched` from the same `[]` is what this
 * value exists to stop. They are not degrees of the same thing: one
 * says the machine will not tell us, the other says we did not ask. */
enum {
    kNowSceneControlsNotFetched = 0,    /* the default: nothing was asked */
    kNowSceneControlsComplete = 1,
    kNowSceneControlsEmpty = 2,
    kNowSceneControlsUnknown = 3
};

typedef struct {
    short number;
    short kind;
    /* As on a control, and it reaches a dialog item by the same join. A
       `resCtrl` DITL row is the one item type whose kind the item list
       cannot name - it says only that a ControlRecord exists - so this is
       precisely where the weaker answer has something to add. */
    short definition;
    char title[kNowSceneDialogTitleMax];
    NowSceneRect rect;
    int enabled;
    int visible;
    char ref[kNowSceneRefMax];
    int state_known;
    int state_on;
    int value_known;
    char value[kNowSceneTextMax];
    int selection_known;
    short selection_start;
    short selection_end;
    int focus_known;
    int focused;
    int default_known;
    int is_default;
    char provenance[32];
} NowSceneDialogItem;

typedef struct {
    char id[kNowSceneIdMax];      /* "<psn>/<title>#<idx>", upstream's form */
    short proc;                   /* index into NowScene.procs */
    char title[kNowSceneTitleMax];
    NowSceneRect rect;
    int front;                    /* front process's frontmost window */
    short z;                      /* stacking index WITHIN its process */
    int visible;

    /* windowKind from the WindowRecord. Absent until the record
       validated, which is why the flag is separate from the value: 0 is
       a legal kind, so a zero cannot mean "not read". */
    short kind;
    int kind_known;

    /* WHICH TITLE-BAR WIDGETS THE MACHINE DRAWS — the WindowRecord's own
       goAwayFlag and spareFlag. Separate known bit for the same reason
       `kind_known` is separate: 0 is a legal answer, so a zero cannot mean
       "not read". A consumer reads absence as "not reported" and keeps
       whatever it did before; it does NOT read it as "no such widget". */
    int widgets_known;
    int has_close_box;
    int has_zoom_box;

    /* The control plane for THIS window. `controls_present` is the
       looked-at-all bit: 1 with a zero count encodes "this window has no
       controls", which is a real answer; 0 encodes "this producer did
       not report controls for this window", which is a different one. */
    int controls_present;
    short first_control;          /* index into NowScene.controls */
    short control_count;

    int dialog_items_present;
    short first_dialog_item;
    short dialog_item_count;

    /* WHY THIS WINDOW IS SILENT, per window rather than per scene.
     *
     * `controls: []` is emitted for a window whose controls were never
     * read as well as for one that genuinely has none, because the IR
     * declares the key required. The distinction used to live only in a
     * scene-wide `controls omitted` sentence in meta.errors - true, and
     * it names no window, so a driving agent meeting an empty list could
     * not tell "this panel has no controls" from "this panel's controls
     * failed to read". Measured 2026-08-07: the Appearance control panel
     * publishes zero controls and zero dialog items, its walk having
     * been retracted, and nothing in the scene said which window that
     * sentence was about. That is the same disease as an act reporting
     * success it cannot verify - a confident answer where the honest one
     * is "unknown". */
    short walk_verdict;           /* kNowSceneWalk*; 0 = nothing to report */

    /* HOW LONG THE CHAIN ACTUALLY WAS, which is the number the verdict
       above could not say.
     *
       "The bound is ours, not the machine's" is the right answer and
       still leaves the next question unanswered: ours by how much? The
       Appearance control panel cost a whole investigation to establish
       that its chain is 73 and the bound was 48, and every fact in that
       sentence was already in the guest's hand at the moment it gave
       up. A cap raised without it is a cap fitted to one panel.
     *
       Counted by hopping the rest of the chain WITHOUT recording it, so
       it costs pointer reads and no pool slots. 0 = not measured.
       `control_chain_len_exact` distinguishes a completed count from one
       that hit the diagnostic probe bound in turn, because "at least
       512" and "exactly 512" argue for different caps - and a cyclic
       chain, which is the other thing this bound catches, argues for
       neither. */
    short control_chain_len;
    int control_chain_len_exact;

    short text;                   /* index into NowScene.texts; -1 = absent */

    char ref[kNowSceneRefMax];    /* "" = not minted, key stays absent */

    /* THE WINDOW RECORD'S OWN ADDRESS, and the only exact join key
       between this scene and the machine it describes.
     *
       Everything else about a window is ambiguous across the seam:
       titles collide (two "Untitled"), modal alerts have none, and
       `id` is "<psn>/<title>#<idx>", which changes when the title or
       the stacking does. A diff keyed on any of those is a heuristic,
       and a heuristic oracle is worse than none - it reports a
       mismatch that is really a mis-join.
     *
       0 means the producer could not say. Self-described windows carry
       the WindowRef, which is the same pointer the Window Manager
       hands anyone; walked windows carry the record address the walk
       already read. Unknowns stay absent keys. */
    unsigned long addr;
} NowSceneWindow;

typedef struct {
    char title[kNowSceneItemTitleMax];
    short index;                  /* 1-based, matching MenuSelect */
    int separator;                /* the Menu Manager's "-" item */
    int enabled;
    int mark;
    char cmd;                     /* command-key char, or '\0' for none */
} NowSceneMenuItem;

typedef struct {
    char title[kNowSceneMenuTitleMax];
    short id;
    short left;                   /* the title's left edge in the menu bar */
    int items_present;            /* as for controls: looked, vs not walked */
    short first_item;             /* index into NowScene.menu_items */
    short item_count;
} NowSceneMenu;

/* THE THEME'S OWN COLOURS, ASKED RATHER THAN GUESSED.
 *
 * Every one of these is a fill the MACHINE makes: the Appearance
 * Manager erases a Dialog Manager window with a brush, and a renderer
 * that wants to redraw that window has to know which colour came out.
 * Until this struct existed the host side carried the answer as a
 * constant COUNTED OFF A SCREENDUMP (0xDDDDDD, 10149 of 11724 interior
 * pixels of one control panel, 2026-08-07) - right for the shipped
 * Platinum theme and silently wrong for any other, which is the exact
 * failure `ppat` 16 had on the desktop: a shipped default nobody
 * updates, plausible for years.
 *
 * WHERE THE LINE IS. These four are brushes and low-memory colours the
 * Toolbox itself hands out, so the theme is their author. The renderer's
 * bevel ramp (its light/shadow greys) is NOT here and deliberately: no
 * guest source asks for a bevel brush, those greys are this side's
 * drawing of the Platinum 3D idiom rather than a fill the machine made,
 * and a field with no producer on the machine is a guess wearing a
 * wire format. See docs/theme-colours.md.
 *
 * Each is 0xRRGGBB, 8 bits per channel, or -1 when the ask FAILED - and
 * -1 means "this machine would not say", never "black". A producer that
 * never asks leaves all four at -1 and the key never reaches the wire,
 * which is scene.h's absent-means-unknown rule applied to colour. */
typedef struct {
    long dialog_background;       /* kThemeBrushDialogBackgroundActive */
    long alert_background;        /* kThemeBrushAlertBackgroundActive */
    long document_background;     /* kThemeBrushDocumentWindowBackground */
    long highlight;               /* LMGetHiliteRGB - the selection fill */
    /* The depth the brushes were asked AT. A brush answers differently
       on a 256-colour screen than on millions, so a colour with no depth
       beside it cannot be checked against a screendump taken later. */
    short depth;                  /* < 0 = not recorded */
} NowSceneTheme;

typedef struct {
    long version;
    long seq;
    double captured_at;           /* Unix epoch seconds, guest clock */
    char source[kNowSceneSourceMax];
    short screen_w, screen_h;
    NowSceneTheme theme;
    /* WHAT THE DESKTOP IS DRAWN FROM, asked of this machine.
       Beside the theme and the screen size for the same reason all three
       are here: they describe the surface a consumer is redrawing, and
       any of them can be changed while this guest runs.
       The renderer's alternative was the offline asset pack's record of
       the image it was extracted from - true only for a guest booted from
       that image and unchanged since, and silently wrong the moment
       either stops holding. This is the live half; the pack is now the
       declared fallback. `asked` 0 leaves the key off the wire entirely. */
    NowDesktopFacts desktop;
    char plane[kNowScenePlaneMax];        /* meta.plane, a freeform note */
    long latency_ms;                      /* < 0 = absent */

    unsigned long now_ticks;              /* the caller's TickCount frame */
    unsigned long stale_after_ticks;      /* 0 disables the age gate */

    NowSceneProc procs[kNowSceneMaxProcs];
    short proc_count;
    int procs_truncated;
    NowSceneCoverage processes_coverage;
    /* DID THIS PRODUCER ESTABLISH WHAT EACH PROCESS IS?
       `backgroundOnly` rides the wire only when true, because 40 process
       rows times two arrays of `,"backgroundOnly":false` is 1.8 KB
       against a 64 KB ceiling this scene already nearly touches. That
       makes a missing key ambiguous by itself - "has a face" and "this
       producer never heard of the question" look identical - and a
       consumer needs them apart or it can never report the middle state
       (a face with nothing open) at all.
       So the answer is given ONCE, in the vocabulary the IR already has
       for exactly this: a `process-kind` coverage claim. `complete` means
       every row's kind was read, so an absent key on a row means that row
       has a face. `partial` means at least one process could not be read.
       `unavailable` - the value a producer that never sets this leaves
       behind - means the question was not asked, and a consumer must then
       treat every absent key as unknown rather than as a face.
       This is scene.h's own `_present` idiom: the looked-at-all bit lives
       beside the data rather than being guessed from it. */
    NowSceneCoverage process_kind_coverage;

    /* DOES THE WINDOW ORDER IN THIS SCENE MEAN ANYTHING ACROSS
       APPLICATIONS?
       The array's order IS the stacking order - front first - and within
       a process it is exact, because the process's own WindowList chain
       is exactly that and `z` says so. Across processes there is no
       chain to read: WindowList is a per-process low-memory global, so
       no application's chain reaches another's, and the Process
       Manager's enumeration is launch order rather than layer order
       (measured: four captures of one run put the same four background
       applications in the same order regardless of which had just been
       fronted). See front_order.h.
       So this claim says which it is. `complete` - every application
       contributing a window had been watched coming to the front, and
       the order across them is a fact. `partial` - at least one had not,
       and its position among the others is a fallback rather than a
       claim. `unavailable`, the value a producer that never sets this
       leaves behind, means the question was not asked at all, and a
       consumer must read the cross-application order as unknown.
       A renderer that draws this array back-to-front is right to; what
       it has never been able to do is tell a known order from a guessed
       one, and this is that bit. */
    NowSceneCoverage depth_coverage;

    /* HOW MANY APPLICATIONS THE ORDER LEDGER HAS FORGOTTEN.
       front_order.h keeps 32 slots and counts what it evicts, precisely
       because "this process has no rank because we forgot it" and "this
       process has no rank because we never saw it come forward" are
       different facts. That count stayed inside the guest, so the second
       was the only one a consumer could read - the empty/unknown
       conflation this IR spends most of its vocabulary preventing,
       arriving in the one plane whose whole subject is order.
       0 means nothing was forgotten, which is the ordinary case and is
       why it rides the wire only when nonzero. */
    unsigned long depth_evicted;

    NowSceneWindow windows[kNowSceneMaxWindows];
    short window_count;
    int windows_truncated;

    /* The menu bar: ONE per scene, because classic Mac OS draws one -
       the front process's. `menubar_present` is the plane bit; a present
       menubar with zero menus says the front process has no menu bar,
       which a faceless background application genuinely does not. */
    int menubar_present;
    int menubar_refused;          /* opened, then dropped: see the retract */
    short menubar_proc;           /* the process it belongs to, or -1 */
    NowSceneMenu menus[kNowSceneMaxMenus];
    short menu_count;
    int menus_truncated;
    NowSceneMenuItem menu_items[kNowSceneMaxMenuItems];
    short menu_item_count;
    int menu_items_truncated;     /* a menu's items were dropped, see above */

    NowSceneControl controls[kNowSceneMaxControls];
    short control_count;
    int controls_truncated;       /* a window's controls were dropped */

    NowSceneListCell list_cells[kNowSceneMaxListCells];
    short list_cell_count;
    int list_cells_truncated;

    NowSceneDialogItem dialog_items[kNowSceneMaxDialogItems];
    short dialog_item_count;
    int dialog_items_truncated;

    NowSceneText texts[kNowSceneMaxTexts];
    short text_count;
    int texts_truncated;          /* a window's text did not fit the pool */
} NowScene;

/* --- assembly (scene_build.c) ------------------------------------------ */

/* Starts an empty scene. `source` is the plane discriminator IR v1
   promoted precisely so a consumer can tell "no windows" from "windows
   not visible from here" - NOW's is "peek" (see docs/scene-producer.md).
   `now_ticks` and `stale_after_ticks` are the age gate: a nonzero
   window turns an otherwise-clean anchor older than it into a REPORTED
   staleness, never a refusal, which is the oracle's own rule for the
   verdict (peek_oracle.h, kNowPeekAnchorStale). */
void now_scene_begin(NowScene *s, long seq, double captured_at,
                     const char *source, short screen_w, short screen_h,
                     unsigned long now_ticks, unsigned long stale_after_ticks);

/* Adds a process row and returns its index, or -1 when the scene is full
   (which sets procs_truncated - a dropped process is reported, never
   silently absent). `anchor` is the reader's verdict for this partition;
   `stamp_ticks` is the anchor's capture tick and is only meaningful when
   the verdict admits data. */
int now_scene_add_process(NowScene *s, long psn_hi, unsigned long psn_lo,
                          const char *name, unsigned long signature,
                          int front, NowSceneAnchor anchor,
                          unsigned long stamp_ticks);

/* Typed IR v2 collection authority and durable process identity. A zero
   incarnation is unknown and stays absent from the wire. */
void now_scene_set_processes_coverage(NowScene *s,
                                      NowSceneCoverage coverage);
void now_scene_set_process_incarnation(NowScene *s, int proc,
                                       unsigned long incarnation);
void now_scene_set_windows_coverage(NowScene *s, int proc,
                                    NowSceneCoverage coverage);

/* --- what the scene refuses to say (scene_build.c) ---------------------
 *
 * Every title in a scene was read out of foreign memory at a literal byte
 * offset, and when the record is not what the walk believed, the same
 * bytes are a 68K address. Both predicates below are the guest's answer
 * to that, stated ONCE and applied by the assembly functions themselves,
 * so no caller can forget them.
 *
 * `now_scene_title_is_publishable` - 1 when a title is bytes a person
 * could read (printable, MacRoman's high half included), or is absent.
 * The single documented exception is the Apple menu's 0x14. A title that
 * fails is OMITTED by the add functions, never shipped: an element with
 * no name is honest, an element wearing an address is not.
 *
 * `now_scene_rect_is_sane` - 1 when a rect is ordered and every
 * coordinate is inside the plausible QuickDraw range for a machine of
 * this era. A rect that fails is clamped into its window's content box
 * (a degenerate rect at an edge: draws as nothing, hit-tests as
 * nothing) rather than shipped as `l = 16555`, which hit-tests as
 * somewhere and actuates a neighbour.
 *
 * Both are exported for the tests, which drive them directly as well as
 * through the add functions. */
int now_scene_title_is_publishable(const char *title);
int now_scene_rect_is_sane(short t, short l, short b, short r);
/* The process's own `modeOnlyBackground` declaration (see
   NowSceneProc.background_only). The caller passes the bit it read from
   ProcessInfoRec.processMode; this side never derives it from window
   counts, and there is deliberately no way to set it from a walk result.
   No-op for an out-of-range row. */
void now_scene_set_process_background_only(NowScene *s, int proc,
                                           int background_only);

/* Whether this producer established what each process IS - see
   NowScene.process_kind_coverage. A producer that reads processMode for
   every row says `complete`; one that could not read some says `partial`;
   one that never calls this leaves `unavailable`, and its absent
   `backgroundOnly` keys mean unknown rather than "has a face". */
void now_scene_set_process_kind_coverage(NowScene *s,
                                         NowSceneCoverage coverage);

/* Records whether the cross-application order of `windows` is a claim or
   a fallback. See NowScene.depth_coverage. */
void now_scene_set_depth_coverage(NowScene *s, NowSceneCoverage coverage);

/* How many processes the front-order ledger has evicted since this
   launch. Absent from the wire when zero. */
void now_scene_set_depth_evicted(NowScene *s, unsigned long evicted);

/* Adds a window to a process already added. Returns 1 on success, 0 when
   the scene is full (sets windows_truncated) or when `proc` is out of
   range - and 0, deliberately, when that process's verdict does not
   admit data: a window read under an Ambiguous or Mismatch anchor would
   be exactly the coin-flip walk the validation layer exists to refuse,
   and letting it into the scene would deliver it as fact. */
int now_scene_add_window(NowScene *s, int proc, const char *title,
                         short t, short l, short b, short r, int visible);

/* The anchor's capture tick for a process, learned during the walk
   rather than before it (the reader reports the stamp with the window
   list). Re-derives that row's staleness against the scene's clock, so
   the age gate works the same whether the stamp arrives with the row or
   after it. No-op for an out-of-range row. */
void now_scene_set_process_stamp(NowScene *s, int proc,
                                 unsigned long stamp_ticks);

/* meta.plane - a freeform note for a human reading a capture. Its VALUE
   vocabulary is explicitly not frozen upstream (IR-V1.md), so nothing
   may branch on it; what it is for is saying which planes a scene had
   available at all. Bounded copy; a longer note is truncated. */
void now_scene_set_plane(NowScene *s, const char *plane);

/* meta.theme - the colours above. Copies whole; a channel outside
   0..0xFFFFFF is rejected to -1 rather than truncated, because a
   half-copied colour would ride the wire looking measured. */
void now_scene_set_theme(NowScene *s, const NowSceneTheme *theme);

/* meta.desktop - what the machine says its desktop is drawn from. Copies
   whole. A NULL `facts`, or one whose `asked` is 0, leaves the scene's
   copy unasked and the key off the wire; there is no way to publish a
   desktop this producer did not ask for. */
void now_scene_set_desktop(NowScene *s, const NowDesktopFacts *facts);

/* The row index of the most recently admitted window, or -1 when the
   scene has none. The walk needs it: it fills a window's sub-planes
   immediately after the row is admitted, and `now_scene_add_window`
   answers whether, not where. */
int now_scene_last_window(const NowScene *s);

/* The window record's address, for the row just added. No-op for an
   out-of-range row; 0 leaves the key absent. */
void now_scene_set_window_addr(NowScene *s, int index, unsigned long addr);

/* --- the walked sub-planes (scene_build.c) ----------------------------- */

/* windowKind, once the record has validated. No-op for an out-of-range
   row; until it is called the key stays absent, because 0 is a legal
   kind and cannot double as "not read". */
void now_scene_set_window_kind(NowScene *s, int window, short kind);

/* The title-bar widgets the machine draws, once a producer has read them
   from the WindowRecord (or asked Carbon about its own window). Same
   no-op-on-out-of-range and same absent-until-called policy as the kind
   above, and for the same reason: false is a legal answer. */
void now_scene_set_window_widgets(NowScene *s, int window,
                                  int close_box, int zoom_box);

/* Declares that this window's control list WAS walked. Returns 1 when
   the row accepted it, 0 for an out-of-range row. Calling it and adding
   nothing is how a scene says "this window has no controls" - which is
   different from saying nothing at all. */
int now_scene_open_controls(NowScene *s, int window);

/* WHAT IS KNOWN ABOUT THIS WINDOW'S CONTROLS, as one of the four words
   above. Stated ONCE, here, so the wire and any consumer of the struct
   cannot disagree about it. Pure over a window row; native-tested. */
short now_scene_controls_state(const NowSceneWindow *w);

/* Appends a control to a window whose controls are open (adding one
   opens them, since adding a control means the list was walked).
   Returns 1 on success; 0 when the pool is full (which sets
   controls_truncated), when `window` is out of range, or when this
   window's block is not the tail of the pool - a control appended after
   another window has started its own block would silently join the wrong
   window, so it is refused rather than misfiled. */
int now_scene_add_control(NowScene *s, int window, const char *title,
                          short t, short l, short b, short r,
                          int enabled, int visible,
                          short value, short min, short max);

/* The observation reference for a window row, and for one control of a
   window's block (`index` counts from the start of that block, which is
   the order the walk appended them in).

   BOTH ARE COPIES AND NEITHER IS A DECISION. `ref` NULL or empty leaves
   the key absent, which is what a walk that could not mint says. A
   longer string than a reference can be is REFUSED rather than
   truncated: a shortened token is well formed and resolves to nothing,
   which is the one shape of this field that lies. No-op for an
   out-of-range row or index. */
void now_scene_set_window_ref(NowScene *s, int window, const char *ref);
/* The control's true kind, for a reader that knows it. Bounded copy; an
   empty or NULL role leaves the row saying nothing, which is what the
   walk honestly knows. */
/* The index of the most recently appended control of a window, or -1
   when it has none - the control-level twin of now_scene_last_window,
   and needed for the same reason: add answers whether, not where. */
int now_scene_last_control(const NowScene *s, int window);

void now_scene_set_control_role(NowScene *s, int window, int index,
                                const char *role);
/* `origin` is a NowAxDefProcOrigin. Setting it never implies a kind. */
void now_scene_set_control_definition(NowScene *s, int window, int index,
                                      short origin);
/* `state` is a NowCdefState; `id` and `variant` matter only for Named.
   Like the origin above, setting it never implies a kind - it records
   what the Resource Manager answered, and the emitter decides what that
   is worth. */
void now_scene_set_control_cdef(NowScene *s, int window, int index,
                                short state, short id, short variant);
void now_scene_set_control_semantic_value(NowScene *s, int window, int index,
                                          const char *value);
/* Attaches a bounded guest-provided list payload to one control. `complete`
   says the record count equals the List Manager's total cell count; a prefix
   stays useful for presentation but never becomes a complete claim. */
void now_scene_begin_control_list(NowScene *s, int window, int index,
                                  unsigned short total_count, int complete);
int now_scene_add_control_list_cell(NowScene *s, int window, int index,
                                    short row, short column,
                                    const char *text, int selected);

void now_scene_set_control_ref(NowScene *s, int window, int index,
                               const char *ref);
void now_scene_set_control_handle(NowScene *s, int window, int index,
                                  unsigned long handle);

/* Drops a window's control plane entirely, returning its entries to the
   pool. This is the retraction rule: a chain that hit a bound or failed
   validation part way through has produced a list that is short with
   nothing beside it to say so, and an absent key is the only honest
   thing left to emit.

   ALWAYS sets controls_truncated, so the drop reaches meta.errors. A
   retraction that reported nothing would be indistinguishable from a
   window this producer never walked, which is the one confusion the
   present-vs-absent split exists to prevent - the reason it happened
   (a bound, or a refusal) is not worth a second flag, and the notice
   says both. No-op unless the window's block is the tail of the pool. */
void now_scene_retract_controls(NowScene *s, int window);

int now_scene_open_dialog_items(NowScene *s, int window);
int now_scene_add_dialog_item(NowScene *s, int window, short number,
                              short kind, const char *title,
                              short t, short l, short b, short r,
                              int enabled, int visible);
void now_scene_set_dialog_item_provenance(NowScene *s, int window, int index,
                                          const char *provenance);
void now_scene_retract_dialog_items(NowScene *s, int window);

/* The window's own record would not validate, so NO sub-plane was even
   attempted. Distinct from a retraction: nothing was walked, rather than
   walked and dropped, and the two send a reader to different places. */
void now_scene_note_window_unreadable(NowScene *s, int window);

/* Refine a verdict a retraction has already set. Only ever narrows -
   the retraction says a plane was dropped, this says why. */
void now_scene_set_walk_verdict(NowScene *s, int window, short verdict);

/* Records how long a window's control chain was, independent of how much
   of it this scene could carry. `exact` distinguishes a completed count
   from one that stopped at the diagnostic probe bound. See the field. */
void now_scene_set_control_chain_len(NowScene *s, int window, short len,
                                     int exact);

/* A window's TextEdit content. `truncated` says the TERec was longer
   than what is carried. No-op for an out-of-range row; sets
   texts_truncated and leaves the key absent when the text pool is
   full. */
void now_scene_set_window_text(NowScene *s, int window, const char *content,
                               int active, int truncated);

/* Opens the menu-bar plane for a process row. Returns 1 when it opened,
   and 0 - REFUSING the plane - when `proc` is out of range or when that
   process's verdict does not admit data. That is the same independent
   refusal `now_scene_add_window` makes, for the same reason: a menu bar
   read under an Ambiguous or Mismatch anchor is a coin-flip walk, and
   admitting it one layer above the code that declined to make it would
   deliver a guess as a fact. */
int now_scene_open_menubar(NowScene *s, int proc);

/* Drops the whole menu-bar plane. A menu list that failed to parse
   leaves NO menubar key rather than an empty one - the front process
   certainly has a menu bar, so "zero menus" would be false where
   "not reported" is true. Records the drop in meta.errors, on the same
   no-silent-drop rule as the other two retractions. No-op if the plane
   was never opened: a menu bar that was never walked is not one that
   was dropped. */
void now_scene_retract_menubar(NowScene *s);

/* Appends a menu to the open menu bar, returning its index or -1 when
   the bar is not open or the scene is full (which sets menus_truncated -
   a dropped menu is reported, because there is only one menu bar for
   the notice to be about). */
int now_scene_add_menu(NowScene *s, const char *title, short id, short left);

/* Appends an item to a menu, on the same tail-of-pool rule as controls.
   Returns 1 on success, 0 when the pool is full (sets
   menu_items_truncated) or the menu is out of range. */
int now_scene_add_menu_item(NowScene *s, int menu, const char *title,
                            short index, int separator, int enabled,
                            int mark, char cmd);

/* Drops one menu's item list, per the retraction rule. Always sets
   menu_items_truncated, for the reason above. */
void now_scene_retract_menu_items(NowScene *s, int menu);

/* Whether a verdict admits window data at all. Ok and Stale do (Stale is
   reported, not refused); NoWindows does trivially - it IS the empty
   answer; every other verdict does not. */
int now_scene_anchor_admits_windows(NowSceneAnchor a);

/* The per-app error token for a row, or NULL when there is nothing
   wrong. Upstream's `ax_oracle_*` vocabulary where a verdict maps onto
   it, a `now_*` token where NOW has a state upstream has no word for
   (docs/scene-producer.md). Never allocates. */
const char *now_scene_proc_error(const NowSceneProc *p);

/* --- encoding (scene_json.c) ------------------------------------------- */

typedef enum {
    kNowSceneEncodeOk = 0,
    kNowSceneEncodeOverflow       /* nothing written; *needed is set */
} NowSceneEncodeStatus;

/* Encodes the scene as IR v1 JSON into `out`.

   FAILS CLOSED. On overflow nothing usable is left in `out` (it is
   emptied) and *needed is the byte count a complete encode would take,
   including the terminator. A truncated scene is never returned as a
   scene: "a partial or failed walk must never be delivered as a complete
   scene" (docs/streaming-a-scene.md), and half a JSON object is the
   worst possible form of that lie because it does not even parse.

   `needed` may be NULL. `cap` may be 0 (with out NULL) to size a scene
   without encoding it, which is how a serving layer learns that a scene
   does not fit a 4096-byte control frame before it commits to one. */
NowSceneEncodeStatus now_scene_encode(const NowScene *s, char *out, long cap,
                                      long *needed);

/* The same encode, additionally recording WHERE EACH PIECE LANDED for a
   caller that has to talk about one entity's bytes without knowing how
   an entity is encoded - the delta plane (scene_digest.h). `spans` may
   be NULL, which is exactly now_scene_encode.

   Offsets are right in a sizing pass too; HASHES are not, because they
   need the bytes. A caller that sizes first and encodes second must take
   its spans from the second call. */
NowSceneEncodeStatus now_scene_encode_spans(const NowScene *s, char *out,
                                            long cap, long *needed,
                                            NowSceneSpans *spans);

/* The exact byte count now_scene_encode would need, terminator included. */
long now_scene_encoded_size(const NowScene *s);

#endif /* NOW_SCENE_H */
