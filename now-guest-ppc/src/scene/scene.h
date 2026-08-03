#ifndef NOW_SCENE_H
#define NOW_SCENE_H

/* The scene envelope: NOW's guest producing Mirror's frozen v1 scene IR
   over the part of the machine it can honestly walk today.
   (mirror/docs/IR-V1.md; docs/scene-producer.md for what is and is not
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
   `controls[].{role,checked}`, `menus[].apple` and `meta.bytes` are
   omitted, because an empty array asserts "this window has no controls"
   and absence says "this producer does not report controls". Those are
   different claims and the difference is the point (AGENTS.md: record
   unknowns as absent keys, never guesses; IR-V1.md's additive
   discipline expects exactly this of a partial producer).

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

#define NOW_SCENE_IR_VERSION 1

enum {
    kNowSceneMaxProcs = 40,       /* process rows carried per scene */
    kNowSceneMaxWindows = 64,     /* window rows carried per scene */
    kNowSceneNameMax = 32,        /* process name, MacRoman */
    kNowSceneTitleMax = 48,       /* window title, MacRoman */
    kNowSceneSourceMax = 16,
    kNowScenePlaneMax = 64,
    kNowSceneIdMax = kNowSceneNameMax + kNowSceneTitleMax + 16,

    /* THE TITLE BAR THE IR'S TWO RECTANGLES ARE RELATED BY.
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
     * exactly.
     *
     * Measured on a live Finder, 2026-08-02, before this existed: NOW
     * emitted the content region here, so a real hardware click at the
     * point a renderer computes from the document landed twenty pixels
     * below the scroll arrow and the machine did not move. Clicking
     * twenty pixels higher moved it (-4 to 60). The document was wrong
     * and both of its own gates agreed with it. */
    kNowSceneIRTitleBarHeight = 20,

    /* The walk's caps. Each is a BOUND on a scene, not a belief about a
       machine, and each one reports itself when it bites (see the
       retraction rule above). The pools are shared across owners rather
       than sized per owner, because a desktop's controls are not spread
       evenly - one dialog can hold thirty and twenty windows hold none -
       and a per-window array of thirty would cost 64 x 30 entries to
       serve the same scene.

       The scene struct they size is ~27 KB measured on the host (a
       little less on the guest, where `long` is 32-bit), up from ~11 KB
       before the walk. It is heap-allocated by its caller for that
       reason - a classic Mac stack is 24-32 KB - and a caller that
       cannot get the block says so rather than walking a smaller
       machine. */
    kNowSceneMaxMenus = 16,       /* menus in the one menu bar */
    kNowSceneMaxMenuItems = 96,   /* menu items, pooled across menus */
    kNowSceneMaxControls = 96,    /* controls, pooled across windows */
    kNowSceneMaxTexts = 4,        /* windows carrying TextEdit content */
    kNowSceneMenuTitleMax = 32,
    kNowSceneItemTitleMax = 40,
    kNowSceneCtlTitleMax = 32,
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

typedef struct {
    NowScenePsn psn;
    char name[kNowSceneNameMax];
    unsigned long signature;      /* creator OSType; 0 = unknown */
    int front;                    /* the frontmost process */
    NowSceneAnchor anchor;        /* the verdict for this partition */
    unsigned long stamp_ticks;    /* the anchor's capture tick */
    int stale;                    /* Ok, but older than the caller's window */
    short window_count;           /* windows admitted for this process */
} NowSceneProc;

/* One control, already in GLOBAL coordinates: axwalk translates a
   control's local rect by its window's content origin, so a consumer
   never has to know the local frame.

   `role` and `checked` are NOT here and are not emitted. The walk
   reads a ControlRecord's fields; it does not read contrlDefProc, so it
   cannot say whether a control is a button, a checkbox or a scroll bar -
   and `checked` is meaningless without knowing which. Inventing a role
   from a value range would be exactly the guess the absent-key rule
   exists to prevent.

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
} NowSceneControl;

/* A window's TextEdit content. `truncated` is true when the TERec's own
   length exceeded what is carried, so a consumer says "truncated" rather
   than presenting a prefix as the whole text. */
typedef struct {
    char content[kNowSceneTextMax];
    int active;
    int truncated;
} NowSceneText;

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

    /* The control plane for THIS window. `controls_present` is the
       looked-at-all bit: 1 with a zero count encodes "this window has no
       controls", which is a real answer; 0 encodes "this producer did
       not report controls for this window", which is a different one. */
    int controls_present;
    short first_control;          /* index into NowScene.controls */
    short control_count;

    short text;                   /* index into NowScene.texts; -1 = absent */

    char ref[kNowSceneRefMax];    /* "" = not minted, key stays absent */
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

typedef struct {
    long version;
    long seq;
    double captured_at;           /* Unix epoch seconds, guest clock */
    char source[kNowSceneSourceMax];
    short screen_w, screen_h;
    char plane[kNowScenePlaneMax];        /* meta.plane, a freeform note */
    long latency_ms;                      /* < 0 = absent */

    unsigned long now_ticks;              /* the caller's TickCount frame */
    unsigned long stale_after_ticks;      /* 0 disables the age gate */

    NowSceneProc procs[kNowSceneMaxProcs];
    short proc_count;
    int procs_truncated;

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

/* The row index of the most recently admitted window, or -1 when the
   scene has none. The walk needs it: it fills a window's sub-planes
   immediately after the row is admitted, and `now_scene_add_window`
   answers whether, not where. */
int now_scene_last_window(const NowScene *s);

/* --- the walked sub-planes (scene_build.c) ----------------------------- */

/* windowKind, once the record has validated. No-op for an out-of-range
   row; until it is called the key stays absent, because 0 is a legal
   kind and cannot double as "not read". */
void now_scene_set_window_kind(NowScene *s, int window, short kind);

/* Declares that this window's control list WAS walked. Returns 1 when
   the row accepted it, 0 for an out-of-range row. Calling it and adding
   nothing is how a scene says "this window has no controls" - which is
   different from saying nothing at all. */
int now_scene_open_controls(NowScene *s, int window);

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
void now_scene_set_control_ref(NowScene *s, int window, int index,
                               const char *ref);

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

/* The exact byte count now_scene_encode would need, terminator included. */
long now_scene_encoded_size(const NowScene *s);

#endif /* NOW_SCENE_H */
