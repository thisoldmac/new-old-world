#ifndef NOW_SCREEN_BOUNDS_H
#define NOW_SCREEN_BOUNDS_H

#include <Carbon.h>

/* **This machine's screen, measured once, in one place.**
 *
 * The size of the guest's screen is a fact about the guest, and this is
 * the only code here that establishes it. Everything downstream reads
 * the answer: the scene the host renders and drives from
 * (`scene.screen.w/h`), the Workshop's own placement, the drag bounds.
 *
 * It exists because the same fact was being stated by four different
 * places on the two sides of this product - 800x600 in the host's mirror
 * window, 800x600 in one MirrorKit file, 1024x768 in another, 640x480 in
 * the sentence a language model reads before it aims a click - and the
 * machine was answering all along. Two of those were on this side, as
 * `SetRect(&screen, 0, 20, 800, 600)` fallbacks: a plausible number
 * standing in for a measurement nobody could see fail.
 *
 * **Unknown is a state.** Both calls answer an EMPTY rect / zero size
 * when the Toolbox will not say, and callers must handle that rather
 * than receive something plausible. `empty` would mean the screen has no
 * pixels; this means we could not establish how many it has.
 */

/* The whole main device, in pixels - the number reported over the wire
 * as `scene.screen.w/h`. Zero/zero when there is no main device. */
void now_screen_size(short *w, short *h);

/* The screen a window may live on: the desktop region, which already
 * excludes the menu bar, falling back to the main device's bounds less
 * the menu bar. An EMPTY rect when neither can be measured - a caller
 * that would clamp to it must skip the clamp instead of clamping to
 * nothing. */
void now_screen_desktop(Rect *out);

#endif /* NOW_SCREEN_BOUNDS_H */
