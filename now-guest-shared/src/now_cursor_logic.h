/*
 * now_cursor_logic.h - P8's one decision, with no Toolbox in it.
 *
 * The cursor plane (ext/src/now_ext_cursor.c) is almost all mechanism:
 * three low-memory writes and a Cursor Device Manager call. It makes
 * exactly one DECISION, and it is the one with a person on the other end
 * of it - **may we move the drawn cursor right now, or is somebody else
 * driving this pointer?**
 *
 * That decision is here so the host cc compiles it and
 * `scripts/test-native` can drive it, for the reason P7's dead-man is:
 * the case that matters is a human at the machine, and a rule that can
 * only be exercised by having a human at a Macintosh is a rule nobody
 * ever watches fail. Every function below is pure.
 *
 * THE TICK ARITHMETIC IS THE PART THAT BITES. `TickCount` wraps, and the
 * wrong spelling of "has a second passed" (`now >= then + limit`) is
 * correct for 2.3 years of uptime and then yields forever. It is the
 * same defect P7's logic was mutated to prove, one plane later, which is
 * why it is spelled the same way here and tested the same way.
 */
#ifndef NOW_CURSOR_LOGIC_H
#define NOW_CURSOR_LOGIC_H

#include "peek_table.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Did somebody other than this plane move the pointer?
 *
 * "Not where we left it" is the whole test, and it is enough: the
 * resident writes RawMouse on every placement, so any difference is
 * somebody else's - a person's ADB mouse, the emulated device, or an
 * application that moved the pointer itself. It cannot tell WHICH, and
 * deliberately does not try: the response is the same for all three.
 *
 * `ever_placed` is 0 until this resident has actually MOVED the device
 * once. Until then `last_h`/`last_v` describe nothing and the answer is
 * always "not foreign" - see the body for the boot this got wrong. */
int now_cursor_is_foreign(NowPeekI32 raw_h, NowPeekI32 raw_v,
                          NowPeekI32 last_h, NowPeekI32 last_v,
                          int ever_placed);

/* May the sprite be moved?
 *
 * `owned` is 1 when the caller is holding the pointer for the length of
 * a gesture (a drag) and must never yield - mid-drag the plane IS what
 * is driving, so "it moved since we placed it" is not evidence of a
 * person, and yielding would strand the sprite halfway through a gesture
 * the application is already tracking.
 *
 * Returns 1 to yield. Note the ORDER: `owned` wins over the deadline,
 * because a drag that yields is worse than a drag that fights. */
int now_cursor_should_yield(NowPeekU32 now, NowPeekU32 foreign_ticks,
                            int owned, NowPeekU32 yield_ticks);

/* Where the pointer should end up after a window act that MOVES the
 * window, and whether there is anywhere honest to put it.
 *
 * The other acts in this plane press a point and leave the window where
 * it is, so the acted point is the answer. A `winact move` is the one
 * case where the thing acted upon travels: a person drags a title bar
 * and their hand arrives with the window, so a pointer left at the old
 * coordinates would be sitting over whatever the window uncovered.
 *
 * `origin_known` is 0 when the caller could not read the window's
 * content origin on both sides of the move - a NULL or empty `contRgn`.
 * Returns 1 and fills the point, or 0 meaning DO NOT PLACE: see the body
 * for why the two obvious fallbacks are worse than not moving.
 */
int now_cursor_follow_window(NowPeekI32 click_h, NowPeekI32 click_v,
                             NowPeekI32 old_h, NowPeekI32 old_v,
                             NowPeekI32 new_h, NowPeekI32 new_v,
                             int origin_known,
                             NowPeekI32 *out_h, NowPeekI32 *out_v);

#ifdef __cplusplus
}
#endif

#endif /* NOW_CURSOR_LOGIC_H */
