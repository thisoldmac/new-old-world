/*
 * conwin.h - the interactive console: NOW-68K's SECOND window.
 *
 * A DELIBERATE EXCEPTION, NOT DRIFT. Read this before deciding the next
 * feature gets a window too.
 *
 * window.h says this application is "ONE page, no tabs", the README
 * describes it the same way, and the PowerPC sibling in guest/ has a harder
 * version of the same rule: a new feature there is a Workshop module, never
 * a new window (now/docs/adding-a-workshop-module.md). None of that changed
 * by accident. The human asked for an interactive console in a separate
 * window here, on this guest, and that is the decision this file
 * implements.
 *
 * The reason it is defensible rather than merely permitted: the main
 * window's console pane is a LOG VIEWER - it shows what the wire and the
 * status line said, it takes no input, and it stays exactly that. What is
 * added here needs a keyboard focus, an edit field, an insertion point and
 * a key-by-key event path, none of which the one page has room for beside
 * three connection fields, two controls, a status line and a health
 * readout on a 512x300 window. Making the one page carry both would mean
 * either shrinking the log viewer to a few rows or growing the window past
 * the 180c's 640x480 panel.
 *
 * So: one exception, for one window, with a stated reason. The next feature
 * is still a page on the main window unless someone writes down a reason
 * this good. docs/open-issues.md carries this as a standing entry.
 *
 * WHAT IT RUNS. Not its own commands - commands68.h's table, through
 * now68k_commands_run(), rendered to text by n68_cmdresult.h. A command
 * added to that table appears here and on the wire in the same commit, and
 * there is no second implementation of `launch` to keep in step. That is
 * the whole design and it is not negotiable: see n68_cmdresult.h.
 */
#ifndef NOW68K_CONWIN_H
#define NOW68K_CONWIN_H

#include <Events.h>
#include <MacWindows.h>

/* Opens the console window, creating it on first use, and brings it to the
 * front. Menu-driven (Windows > Console): most runs never open it, so the
 * WindowRecord, its TERec and the text Handle are not paid for until then.
 * The static buffers ARE paid for unconditionally - see conwin.c's budget.
 *
 * Safe to call when the window is already open (it just comes forward), and
 * safe to call when creation fails (it logs and stays closed rather than
 * leaving a half-built window behind). */
void conwin_show(void);

/* True if `w` is this module's window. main.c routes every event through
 * this rather than assuming one window exists - an update or a key for the
 * console must not reach window.c, and vice versa. NULL is not ours. */
int conwin_owns(WindowPtr w);

/* Closes the console window and frees the Toolbox objects behind it. The
 * scrollback and the history survive in BSS, so reopening shows what was
 * there before - closing a console should not silently erase it. */
void conwin_close(void);

/* Routes one event (update, activate, content click, key) that
 * conwin_owns() has already claimed. */
void conwin_handle_event(EventRecord *event);

/* Per-pass idle hook: the insertion point's blink, and nothing else. Costs
 * nothing while the window is closed. Called from main.c's loop alongside
 * window_idle(). */
void conwin_idle(void);

/* Once before the application exits, on every path. */
void conwin_dispose(void);

#endif /* NOW68K_CONWIN_H */
