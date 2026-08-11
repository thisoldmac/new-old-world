#ifndef NOW_ACT_ARGS_H
#define NOW_ACT_ARGS_H

/* The act plane's argument grammar, on the guest side.

   The host decodes these too (AgentIntegrationWindowActRequest), and
   that is not a reason to skip it here. The guest does not trust the
   host to have validated an argument - a typed caller can reach a guest
   directly, and every other command in this table checks its own - and
   the one refusal that matters most is the same on both sides: an
   action's geometry keys are exactly the ones that action takes.

   A close carrying a `width` is not a slightly-wrong close. It is a
   different request, and it is refused rather than performed with the
   rest discarded. That rule is the small, boring cousin of the plane's
   big one: an act whose arguments cannot bound what it does is the
   18/20 defect restated.

   Toolbox-free and JSON-free: it takes values already pulled out of a
   request, so the policy is reachable from now_act_args_test.c. */

/* The four sub-ops, spelled as the wire spells them. Values match the
   resident plane's kNowPeekActWin* so nothing translates twice. */
enum {
    kNowActWinUnknown = 0,
    kNowActWinMove = 1,
    kNowActWinResize = 2,
    kNowActWinZoom = 3,
    kNowActWinClose = 4,
    kNowActWinSelect = 5
};

/* The range a QuickDraw Rect can hold: its members are signed 16-bit, so
   a destination outside this is not a window any machine could have.
   Documented (Inside Macintosh: Imaging With QuickDraw), not measured,
   and it bounds an argument rather than describing a machine. */
enum {
    kNowActCoordMin = -32768L,
    kNowActCoordMax = 32767L,
    kNowActExtentMin = 1L
};

typedef struct {
    int  action;
    long left;
    long top;
    long width;
    long height;
    /* Presence is carried separately from value because the refusal is
       about the KEY SET, not about the numbers: a resize that sent only
       a width has to be told it sent only a width, and a zero is a
       legal-looking value for a key that should not be there at all. */
    int  has_left;
    int  has_top;
    int  has_width;
    int  has_height;
} NowActWinArgs;

/* "select" / "move" / "resize" / "zoom" / "close", else unknown. */
int now_act_win_action(const char *name);

/* The zoom direction: 1 for out (the standard state), 0 for in (back to
   the user state), -1 for anything else. Named as the two zoom part
   codes rather than as a Boolean because the caller passes one on to
   the resident plane, and "true" would not say which box. */
int now_act_zoom_direction(const char *name);

/* 1 when the call is legal. Otherwise 0, with `*reason` set to a
   sentence naming the bound it broke - the wording is the product here,
   the same way it is on the host, so it is carried rather than mapped
   to a code and back. */
int now_act_win_args_check(const NowActWinArgs *args, const char **reason);

#endif /* NOW_ACT_ARGS_H */
