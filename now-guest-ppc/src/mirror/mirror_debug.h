#ifndef NOW_MIRROR_DEBUG_H
#define NOW_MIRROR_DEBUG_H

/* The mirror area's DEBUG TIER, behind one task-time switch.
 *
 * By 2026-08-15 the mirror diagnostics had eaten the log: a three-minute
 * session cycling 18 Continuity epochs left a 2000-line ring that was
 * ~97% `mirror` counter dumps (each disarm writes ~25 lines), and the
 * lines a person actually needs — arm/disarm, selection, grants, errors
 * — were buried past what `tail` can serve. So the firehose is now
 * opt-in: call sites that are per-event traces or per-epoch counter
 * dumps test now_mirror_debug_on() BEFORE formatting anything, and the
 * ring holds the product's story by default.
 *
 * What is NOT behind the switch, ever: lifecycle facts (arm/disarm,
 * epoch begin, selection published, grant held/released, the writer
 * verdict) and every warn/error path. A refusal that only shows up when
 * somebody remembered to enable debugging is the 2026-08-07 silence
 * with an extra step.
 *
 * The switch is SESSION-SCOPED on purpose — no prefs entry. The
 * contract's own wirestat text has the argument: "a diagnostic that
 * survives a relaunch is a configuration nobody chose." A debug flood
 * enabled once and forgotten would rot every later log; a relaunch
 * returns to the product story. Both faces flip it through the one
 * `mirrorlog` command implementation (commands.c), which also logs the
 * transition so the ring names who opened the firehose.
 *
 * This file is pure C with no Toolbox dependency so the grammar and the
 * flag are native-testable (tests/mirror_debug_test.c). */

enum {
    kNowMirrorDebugStatus = 0,        /* report without changing anything */
    kNowMirrorDebugOn,
    kNowMirrorDebugOff
};

/* Whether the mirror debug tier is emitting. Cheap enough for every
   call site: one load. */
int now_mirror_debug_on(void);
void now_mirror_debug_set(int on);

/* One token -> status/on/off. Anything unrecognised (including empty)
   is status, so a typo leaves the machine in the condition the last
   call put it in rather than half-toggling it. */
int now_mirror_debug_parse(const char *action);

#endif /* NOW_MIRROR_DEBUG_H */
