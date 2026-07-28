/*
 * window.h - the NOW-68K single window.
 *
 * ONE page, no tabs. System 7.1 has no Appearance Manager and therefore no
 * tab CDEF, so a tab bar is hand-drawn QuickDraw; that work is deferred to
 * its own slice rather than smuggled into the shell. Connection fields,
 * health readout and console all live on the one page.
 *
 * This header is the seam between main.c's event loop and the window module:
 * main.c never touches WindowPtr or control state directly, so panel content
 * can land without changing main.c. window.c currently provides a placeholder
 * shell so the app builds and launches before any panel exists -
 * guest-ui-start-here.md: put it on the machine before it is finished.
 *
 * NOTE for the transport pass: every nested Toolbox loop must pump the wire
 * (guest-ui-start-here.md, pump.h). A TrackControl with a NULL action proc
 * stops the connection for as long as a finger rests on the button, and
 * MacTCP here is strictly one operation in flight - a standing TCPRcv plus a
 * concurrent TCPSend deadlocks (finding mactcp-concurrent-rcv-send-deadlock).
 * This seam has to grow an action-proc callback before the first control
 * lands; it cannot carry that constraint as it stands.
 */
#ifndef NOW68K_WINDOW_H
#define NOW68K_WINDOW_H

#include <Events.h>

/* Create the single application window. Call once, after Toolbox init. */
void window_init(void);

/* Tear down the window. Call once, before returning from main. */
void window_dispose(void);

/* Route one event to the window (update, activate, content clicks, keys).
 * Idle-free by construction: only runs on an actual event, never polled. */
void window_handle_event(EventRecord *event);

/* Per-pass idle hook, called once every trip through the main loop whether
 * or not an event arrived. Must stay free (no file reads, no unconditional
 * redraws) per guest-ui-start-here.md's idle-work rule - currently a no-op
 * because there is nothing yet that needs polling outside an event. */
void window_idle(void);

/* Apple menu > About. Movable modal rather than an alert: Mac OS reads modal
 * ALERTS aloud, which turns a routine box into a spoken interruption. */
void window_show_about(void);

#endif /* NOW68K_WINDOW_H */
