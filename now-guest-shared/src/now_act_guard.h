#ifndef NOW_ACT_GUARD_H
#define NOW_ACT_GUARD_H

/*
 * now_act_guard.h - the act plane's decisions, with no Toolbox in them.
 *
 * WHY THIS FILE EXISTS AT ALL. The act plane's guard is the difference
 * between a request that drives the element it named and a patch that
 * rides whichever call arrives first. Upstream measured that difference:
 * a request that merely disarmed after one use ran on a real user's
 * press 18 times in 20, and the variant that additionally required the
 * request to name its exact target ran on it 0 times in 20. That is the
 * most expensive fact in the port, and it lives in six small functions
 * below.
 *
 * A guard nobody can test is a guard nobody can trust, and the resident
 * code it runs in executes inside every process that pumps events on a
 * machine with no memory protection - the worst place in this project to
 * find out a comparison was backwards. So every decision is HERE, pure,
 * compiled by the host cc and mutated in now_act_guard_test.c; the
 * resident half (ext/src/now_ext_act.c) performs the Toolbox effect and
 * decides nothing. Same split, and the same reason, as peek_oracle.c
 * against peek_read.c and scene_walk.c against scene_collect.c.
 *
 * No Toolbox here, and no clock: ticks arrive as an argument. That is
 * not cosmetic - it is what lets a test say "this stamp was committed"
 * about code that runs inside somebody else's GetNextEvent.
 *
 * Ported from the sibling Mirror project's Portal INIT (parked, complete,
 * metal-proven upstream). Facts crossed; none of its MEASUREMENTS did.
 */

#include "peek_table.h"

/* ---- the stale-resident gate ------------------------------------------
 *
 * Stated once, here, because every act command asks the same question and
 * a second spelling of it is a second chance to spell it wrong.
 *
 * A resident extension older than this plane allocated a SHORTER table.
 * Writing a request into it runs off the end of a system-heap pointer -
 * silent corruption rather than an error - and leaves the caller
 * believing a guard is armed that has no room to exist. So the answer is
 * a refusal with a name, never a best effort. */
enum {
    kNowActPlaneReady = 0,
    kNowActPlaneNoTable = 1,    /* no table, or not one we trust at all   */
    kNowActPlaneAbsent = 2,     /* the extension does not carry the plane */
    kNowActPlaneStale = 3,      /* length does not cover the act cell -
                                   the resident half predates the plane  */
    kNowActPlaneWrongFormat = 4 /* act_format is not one this build knows */
};

/* Which of the five above. `table` may be NULL. Gates on the format word
 * and on length, NEVER on a field being nonzero: a zeroed cell in a
 * too-short table reads exactly like an idle one. */
int now_act_plane_state(const NowPeekTable *table);

/* ---- the bypass switch -------------------------------------------------
 *
 * The act plane's cell, but ONLY while the application has the plane
 * armed. Returns NULL otherwise, and every patch and the filter's serve
 * path start here - so with the plane disarmed each of them is a load
 * and a branch, and every MenuSelect / TrackControl / FindWindow in the
 * system reaches the real trap exactly as it would with no extension
 * installed.
 *
 * It reads arm_request - the one word the APPLICATION writes - rather
 * than arm_active, and that is deliberate: turning the plane off has to
 * be immediate and must not depend on the target process being alive,
 * frontmost, or pumping its event loop. A safety switch that needs the
 * thing it is protecting you from to cooperate is not a safety switch.
 *
 * The patches themselves are never removed. A patch that vanishes while
 * a caller is inside it is worse than one that stays; disarming makes
 * every one of them chain through instead. */
NowPeekActCell *now_act_armed_cell(NowPeekTable *table);

/* Validate and echo the V2 correlation before the V1 effect decision. PSN is
 * carried and echoed, never used as resident authority; the exact A5/object
 * checks remain the safety gate. Returns 1 when V1 may proceed, 0 when this
 * is not the target's pass, and -1 after publishing a refusal. */
int now_act_v2_begin(NowPeekTable *table, unsigned long current_a5,
                     unsigned long ticks);

/* Advance the matching correlation from accepted to armed/fired/refused.
 * A stage never moves backwards within a generation, and each transition's
 * first timestamp is retained. */
void now_act_v2_note(NowPeekTable *table, unsigned long stage,
                     unsigned long ticks);

/* ---- the serve decision -----------------------------------------------
 *
 * What the filter should do about the pending request, decided before it
 * touches anything. The hook performs the effect; this says whether
 * there is one, and for whom. */
enum {
    kNowActServeSkip = 0,      /* not pending, or not this process       */
    kNowActServeArmed = 1,     /* armed; the patch does the rest         */
    kNowActServeMove = 2,      /* the hook must call MoveWindow          */
    kNowActServeText = 3,      /* the hook must run the text op          */
    kNowActServeSelfTest = 4,  /* the hook must run the ABI selftest     */
    kNowActServeRefused = 5,   /* refused; status and error are written  */
    kNowActServeDialogItem = 6,/* validate and queue one DITL press      */
    kNowActServeSelect = 7,    /* the hook must call SelectWindow        */
    kNowActServeVisibility = 8, /* queue a Process Manager visibility key */
    /* P7. Hand the gesture to the drag vehicle: press, and leave the
       button down. The ONLY drag verdict there is - motion and release
       are not served here and could not be, because from the press until
       the release the application is inside its own tracking loop and
       the filter this verdict comes from is never entered again. */
    kNowActServeDragPress = 9
};

/* Claim the request if it names THIS A5 world, and say what to do with
 * it. Opens the seqlock (seq becomes odd) for every verdict except Skip,
 * so a caller that gets anything else MUST reach now_act_serve_commit.
 *
 * `patches` is what the plane actually installed; a sub-op whose patch is
 * missing is refused rather than armed, because arming something that can
 * never fire produces a timeout that names the wrong repair. */
int now_act_serve_begin(NowPeekActCell *cell, unsigned long current_a5,
                        unsigned long ticks);

/* Close the seqlock and publish the outcome. `error` of kNowActErrNone
 * means done. Called exactly once per non-Skip begin. */
void now_act_serve_commit(NowPeekActCell *cell, unsigned long error);

/* ---- the six patch guards ---------------------------------------------
 *
 * Each answers the application's own trap, or declines. Declining is
 * always spelled as a value the real trap could itself have returned, so
 * a decline is indistinguishable from an ordinary miss and the shim
 * chains through with the stack untouched.
 *
 * Every one of them checks, in this order: the plane is armed at the
 * right stage, for the right op, in the A5 world running right now, NOT
 * stale, AND the request names THIS target. The last clause is the
 * guard.
 *
 * THE AGE-OUT BOUND. now_act_submit (act_client.c) already withdraws a
 * request the CALLER gave up waiting on - but that withdrawal runs in
 * the calling application's own loop, on its own stack, and upstream's
 * arc names the exact failure mode when that stops being true: nothing
 * else ever clears the cell, so an agent that dies between arming a
 * patch and reaching its own withdraw leaves that patch live on the
 * target process INDEFINITELY, with no caller left to time it out.
 * Upstream never closed this; it stayed "only the arming verb's exit
 * path or the bypass switch clears it."
 *
 * Here the resident guard itself owns a second, independent clock: every
 * armed stage carries the tick it was armed at (served_ticks, already
 * written by now_act_serve_begin and re-stamped at the stage-2
 * transition), and armed_for's age check compares that against the
 * ticks the CURRENT trap call carries - not against wall-clock time this
 * file cannot read. A stale-by-age cell is cleared and declined exactly
 * like a cell naming the wrong target: this side owes no explanation to
 * a caller that is not there to hear one. kNowActArmTicksMax is set
 * comfortably above the caller's own kNowActDeadlineTicks (act_client.c)
 * so a live caller's own timeout always fires first; this bound exists
 * for the caller that cannot fire its own. */
enum {
    /* ~20s at 60 ticks/sec (Inside Macintosh: Operating System
       Utilities, TickCount). About 4x the caller's own 300-tick (~5s)
       deadline - generous enough that a live, merely slow caller is
       never pre-empted by this backstop, small enough that a dead one
       does not leave a patch armed for the rest of the session. */
    kNowActArmTicksMax = 1200UL
};

/* MenuSelect. Returns the packed (menuID << 16 | item) to answer with, or
 * 0 for "not ours".
 *
 * `start_pt` is MenuSelect's own Point argument packed as (v << 16) | h.
 * A menu press carries no handle to name, so the identity checked is the
 * press itself: the caller synthesised it, so it knows the exact point
 * MenuSelect will receive, and a press anywhere else is somebody else's.
 * Tolerance is +/-2 px and errs LOOSE deliberately - an application is
 * free to adjust the point it passes on, and a guard wrong in the strict
 * direction breaks the legitimate request rather than the hijack. */
long now_act_menu_answer(NowPeekActCell *cell, unsigned long current_a5,
                         long start_pt, unsigned long ticks);

/* TrackControl. Returns the part code to answer with, or 0 to decline -
 * which is also TrackControl's own "released outside the control".
 *
 * `*out_action` is set to the action procedure the caller should invoke
 * once, or 0 for none. A push button does its work AFTER TrackControl
 * returns, from the part code, so answering is enough; a scroll bar does
 * its work DURING tracking, in the action procedure. Once, not
 * repeatedly: a caller that wants to page twice asks twice, and a loop
 * would be a held button nobody asked for. 0xFFFFFFFF is the Control
 * Manager's "use the control's own" sentinel and is NOT an address -
 * calling it would jump to 0xFFFFFFFF - so it is filtered here rather
 * than in the resident code that would do the jumping. */
short now_act_control_answer(NowPeekActCell *cell, unsigned long current_a5,
                             unsigned long control_handle,
                             unsigned long action_proc, unsigned long ticks,
                             unsigned long *out_action);

/* Count one trap entry, before any guard runs. Separate from the guards
 * so it happens even when one is about to decline: "never called" and
 * "called and declined" are opposite repairs and without this they are
 * the same symptom. */
void now_act_trap_hit(NowPeekActCell *cell, int index,
                      unsigned long current_a5);

/* FindWindow. Returns the part code, or 0 to decline - and 0 is inDesk, a
 * real answer, so the shim chains rather than returning it.
 *
 * `point` is the Point as its raw 32 bits; a Point is {short v; short h},
 * so v is the HIGH word. Answers at EITHER arm stage: upstream measured
 * one posted click producing TWO FindWindow entries, and a patch that
 * answers only the first hands the application its part code and then
 * lets the real trap overrule it with inContent. `*out_window` receives
 * the WindowPtr the request names. */
short now_act_findwindow_answer(NowPeekActCell *cell, unsigned long current_a5,
                                unsigned long point, unsigned long ticks,
                                unsigned long *out_window);

/* GrowWindow. Returns the packed new size, or 0 to decline - and 0 is
 * GrowWindow's own "the user changed nothing".
 *
 * The packing is documented: the HIGH word is the new height and the low
 * word the new width. That order is easy to get backwards and nothing in
 * the headers states it, so it is pinned by a test here and settled by
 * measurement on a machine - a swapped pair turns a 420x260 request into
 * 260x420, which fails loudly rather than quietly. */
long now_act_grow_answer(NowPeekActCell *cell, unsigned long current_a5,
                         unsigned long window, unsigned long ticks);

/* TrackBox. Returns 1 to answer true, 0 to decline. Declines when the
 * application is tracking a different box than the one FindWindow was
 * answered with - the request stays at stage 2 and the caller's timeout
 * withdraws it, which is honest where guessing would not be. */
int now_act_trackbox_answer(NowPeekActCell *cell, unsigned long current_a5,
                            unsigned long window, long part,
                            unsigned long ticks);

/* TrackGoAway. Returns 1 to answer true, 0 to decline. What happens next
 * belongs to the application, including its save-changes dialog - which
 * is the entire reason this op closes a window by ASKING rather than by
 * calling CloseWindow behind the application's back. */
int now_act_goaway_answer(NowPeekActCell *cell, unsigned long current_a5,
                          unsigned long window, unsigned long ticks);

/* ---- the text ops' identity check -------------------------------------
 *
 * The text ops arm no patch, so the hazard is not "the wrong moment" but
 * "the wrong object", and the check is correspondingly stricter: the
 * named window must be in the SERVING process's own window list. Nothing
 * is written on the strength of a request being pending. */

/* How the walk reads the next window. A seam rather than a WindowPeek
 * dereference so the bounded-walk decisions - the cap, the cycle, the
 * miss - are reachable from a host test against a synthetic list. */
typedef unsigned long (*NowActNextWindow)(unsigned long window, void *ctx);

/* A corrupt nextWindow chain must cost a loop count, not the machine. */
enum { kNowActMaxWindowWalk = 64 };

/* 1 when `want` is reachable from `list_head` within the cap. A cycle
 * ends the walk at the cap and answers 0, because a walk that cannot
 * finish has not proved anything. */
int now_act_window_is_ours(unsigned long list_head, unsigned long want,
                           NowActNextWindow next, void *ctx);

/* Could `addr` plausibly be a handle into a heap zone bounded by
 * [lo, hi), with `need` bytes of record behind it?
 *
 * This exists because of a measured failure: a text request naming a
 * caller-supplied handle of 1234 did not come back refused, it hung and
 * took the target application with it. The identity check it was about to
 * run - the TERec's inPort against the named window - is two levels of
 * dereference of an arbitrary integer, and it was running BEFORE anything
 * had established that the integer addressed memory at all.
 *
 * So the ORDER is the fix and it is why this is split in two: bound the
 * handle, then read the master pointer, then bound that too, and only
 * then dereference the record. It is a PLAUSIBILITY test, not a proof -
 * an in-zone address that is not a TEHandle still gets past - which is
 * why the inPort check remains and remains the identity guard. What this
 * rules out is the wild read. */
int now_act_handle_in_zone(unsigned long lo, unsigned long hi,
                           unsigned long addr, unsigned long need);
int now_act_master_in_zone(unsigned long lo, unsigned long hi,
                           unsigned long master, unsigned long need);

/* Is this dialog item type one that holds text? itemDisable (128) rides
 * in the high bit of the type byte and is masked off before comparing;
 * an unmasked compare is how a disabled static field reads as "not
 * text". editText is 16 and statText 8 (Dialogs.h). */
int now_act_item_type_is_text(long type);

/* How many bytes of a set request to actually write, given what the
 * caller asked and what the RESIDENT half allocated. Clamped to the
 * extension's own buffer rather than to this build's constant: the two
 * can differ across a version, and the one that matters is the memory
 * that exists. */
long now_act_text_take(long requested, long buffer_max);

#endif /* NOW_ACT_GUARD_H */
