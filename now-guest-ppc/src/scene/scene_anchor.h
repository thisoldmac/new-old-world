#ifndef NOW_SCENE_ANCHOR_H
#define NOW_SCENE_ANCHOR_H

/* The reader's verdict vocabulary, restated where a native test can
   reach it.

   peek_read.h is the definition, and it cannot be included here: it
   includes <Carbon.h> for ProcessSerialNumber, which is exactly what
   keeps the scene assembly (and its tests) off a Macintosh. So the
   values below are the SAME NUMBERS in the same order, and
   scene_collect.c - the one file that sees both headers - pins them with
   a compile-time check. Change one enum without the other and the guest
   build fails; that check is the whole reason this is a copy rather than
   a translation table someone maintains by hand.

   Five of these come from the anchor oracle (peek_oracle.h), which
   answers with a VERDICT rather than a pointer because three of its
   answers are cases where returning a pointer would be a lie. A scene
   has to render them honestly rather than flattening them to "no
   windows": a process whose anchor is ambiguous is not a process with
   zero windows. */

typedef enum {
    kNowSceneAnchorOk = 0,        /* data present */
    kNowSceneAnchorNoPlane,       /* extension absent, or anchors not armed */
    kNowSceneAnchorNotFound,      /* no fresh in-partition anchor */
    kNowSceneAnchorNoWindows,     /* anchor found, process has no windows */
    kNowSceneAnchorUnreadable,    /* anchor found, the walk failed validation */
    kNowSceneAnchorStub,          /* a plane whose walk is not built yet */
    kNowSceneAnchorAmbiguous,     /* two anchors claim it; refused, not guessed */
    kNowSceneAnchorMismatch       /* A5 and stack base disagree: recycled slot */
} NowSceneAnchor;

/* The verdict as the token a scene puts in `apps[].error`, or NULL when
   the verdict is not an error.

   Upstream's own vocabulary wherever the verdict maps onto it -
   `ax_oracle_not_found`, `ax_oracle_ambiguous`, `ax_oracle_mismatch`,
   `ax_oracle_stale`, `ax_read` - because inventing a second word for a
   state that already has one is how two vocabularies for one thing
   start. Where NOW has a state upstream has no word for (the anchor
   plane itself absent, or a walk that is not built yet) the token is
   prefixed `now_`, so a consumer can see at a glance which words are the
   IR's and which are this producer's. Never NULL for an error verdict,
   never allocates. */
const char *now_scene_anchor_error(NowSceneAnchor a);

/* The stale token, which is not a verdict of its own here: peek_read.c
   runs with no age gate, so an old-but-clean anchor arrives as Ok with
   an old stamp, and staleness is derived by the scene from the stamp and
   the caller's clock. Reported, never refused. */
const char *now_scene_stale_error(void);

#endif /* NOW_SCENE_ANCHOR_H */
