#ifndef NOW_SCENE_H
#define NOW_SCENE_H

/* The scene envelope: NOW's guest producing Mirror's frozen v1 scene IR
   over the part of the machine it can honestly walk today.
   (mirror/docs/IR-V1.md; docs/scene-producer.md for what is and is not
   produced, and why.)

   THE PRODUCED SUBSET is `version` / `seq` / `capturedAt` / `source`,
   `screen.{w,h}`, `apps[].{psn,name,front,error}`,
   `processes[].{psn,name,front,signature}`,
   `windows[].{id,app,psn,title,rect,front,z,visible}` and `meta`.

   EVERYTHING ELSE IS AN ABSENT KEY, NOT AN EMPTY ONE. `menubar`,
   `menus[]`, `windows[].controls`, `windows[].text`,
   `windows[].display[]`, `desktopItems[]` and `windows[].kind` are
   omitted, because an empty array asserts "this window has no controls"
   and absence says "this producer does not report controls". Those are
   different claims and the difference is the point (AGENTS.md: record
   unknowns as absent keys, never guesses; IR-V1.md's additive
   discipline expects exactly this of a partial producer).

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
    kNowSceneIdMax = kNowSceneNameMax + kNowSceneTitleMax + 16
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

typedef struct {
    char id[kNowSceneIdMax];      /* "<psn>/<title>#<idx>", upstream's form */
    short proc;                   /* index into NowScene.procs */
    char title[kNowSceneTitleMax];
    NowSceneRect rect;
    int front;                    /* front process's frontmost window */
    short z;                      /* stacking index WITHIN its process */
    int visible;
} NowSceneWindow;

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
