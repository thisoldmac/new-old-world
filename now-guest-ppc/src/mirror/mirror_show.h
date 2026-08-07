#ifndef NOW_MIRROR_SHOW_H
#define NOW_MIRROR_SHOW_H

#include "wire.h"

/* **Asking the host to show its Mirror, once, for both faces.**
 *
 * The Mirror page's button and the console's `showmirror` verb are two
 * renderers over this file. That is the command-parity rule stated for
 * a capability that happens to travel the other way: a person at this
 * keyboard must be able to reach it whether they are clicking or
 * typing, and neither face may decide anything the other does not.
 *
 * Why the capability exists at all: the Mirror is the HOST's rendering
 * of THIS machine's screen, so the person who wants one open is
 * usually sitting here — and until this landed the only ways to open
 * one in a running host were a click on that Mac and a launch flag.
 *
 * Every string a person reads lives here rather than in either face,
 * for the reason `diag_layout.h` holds its sentences: this file has no
 * Toolbox dependency and is compiled by the host `cc` for its native
 * test, and the two faces cannot drift into saying different things
 * about one act.
 */

/* The only surface name the contract declares today. */
#define kMirrorHostSurface "mirror"

const char *now_mirror_show_button_title(void);

/* Shown from the moment the ask is on the wire until the host answers
 * or the deadline settles it. A button that reports nothing while it
 * waits is a button a person presses twice.
 */
const char *now_mirror_show_waiting_text(void);

#endif /* NOW_MIRROR_SHOW_H */
