#ifndef NOW_MIRROR_LOG_H
#define NOW_MIRROR_LOG_H

#include <Carbon.h>

#include "peek_lease.h"

/* **The Mirror's account of itself, in the log.**
 *
 * Until this file existed the Mirror wrote NO log line at all — not one
 * `mirror` line anywhere in the guest — and the cost was measured on
 * 2026-08-07: the feature crashed NOW reproducibly on the PowerBook
 * 1400c, four guest logs from that session were recovered, and every one
 * of them said only what NOW happened to be doing when it stopped. Six
 * plausible mechanisms were read out of the source afterwards and not
 * one of them could be falsified, because the instrument could not see
 * the defect. That is this project's recurring shape.
 *
 * **WHERE THIS MAY RUN, and it is the whole design constraint.**
 *
 * Every function here runs at TASK TIME, on the application side, from
 * the event loop or from a wire command being served. Nothing here may
 * ever be called from the resident's QuickDraw bottlenecks, its trap
 * patches or its jGNE filter: those run INSIDE FOREIGN PROCESSES at draw
 * time and are bounded and allocation-free by construction
 * (ext/src/now_content.c says so in its own comments). A disk write
 * there would change the timing of the thing being measured and could
 * take the Finder down with it — far worse than the silence it would be
 * fixing.
 *
 * So a fact that is only knowable inside a hook is surfaced as a COUNTER
 * the resident bumps and this side reads (`NowContentCounters`), never
 * as a line the resident writes. `now_mirror_log_idle` is that reader.
 * `LoggingSpecTests.testTheResidentNeverLogs` is the gate.
 *
 * **Everything here is edge-triggered**, and that is not tidiness
 * either: log rotation does not exist on this guest (docs/logging.md,
 * "Rotation" — specified, never built), so a file per launch accumulates
 * forever on a disk with tens of megabytes free. A line per event-loop
 * pass would be a heartbeat, which rule 1 forbids, and here it would
 * also be a slow disk leak. Each call below compares against what it
 * last said and returns having written nothing when the answer has not
 * changed. */

/* Why this application is, or is not, the shared table's writer.
 *
 * `kMirrorWriterNotCanonical` is the reason this file was written for.
 * AGENTS.md records that a binary not named exactly `New Old World`
 * (creator `NOWo`) arms NO PLANE AT ALL, while the resident goes on
 * reporting `active` with full capabilities and nothing anywhere names
 * the cause; it took renaming a build to discover, and it took
 * `requested` from 0 to 15 with nothing else changed. It is one line
 * now. */
typedef enum {
    kMirrorWriterOwned = 0,   /* this build owns the writer lease      */
    kMirrorWriterNoResident,  /* Gestalt 'NWex' silent or table rejected */
    kMirrorWriterNoRegion,    /* resident predates the writer lease    */
    kMirrorWriterNotCanonical,/* the silent one: wrong name or creator */
    kMirrorWriterOtherSession /* another live session holds the table  */
} MirrorWriterVerdict;

/* The writer verdict, deduped on (verdict, session). Cheap enough for
   the idle path: two comparisons when nothing has changed. */
void now_mirror_log_writer(MirrorWriterVerdict verdict, unsigned long session);

/* A plane arm/disarm REQUEST reaching the shared table, named by the
   owner that moved it. Silent when the published union is unchanged —
   a claim that asks for what is already asked for is not an event. */
void now_mirror_log_request(int owner, unsigned long before,
                            unsigned long after);

/* The OUTCOME of waiting for the resident to echo a request. Failures
   carry their reason; identical consecutive failures are collapsed and
   the count is reported when the answer finally changes, so a host
   polling at 4 Hz cannot flood the ring with one sentence. */
void now_mirror_log_settle(unsigned long caps, int armed, const char *why);

/* Every plane released because the link went away. */
void now_mirror_log_disconnect(unsigned long before);

/* The Workshop's Mirror page: created, disposed, shown, hidden. A page
   the person was looking at when the machine stopped is context the four
   recovered logs did not have. */
void now_mirror_log_page(const char *event);

/* The slow observer, from the main loop. Polls the resident's own
   counters — hooks installed and removed, ports skipped and why, arm
   refusals, retires — and writes only what changed. This is the ONLY
   place those numbers come from: they are counted inside the hooks and
   surfaced here, never recounted on this side. */
void now_mirror_log_idle(void);

/* Teardown, flushed. A launch whose log has no `teardown` line is one
   where teardown DID NOT RUN, and that absence is itself the finding —
   the same reading docs/logging.md gives a file with no `stopped`. */
void now_mirror_log_teardown(void);

#endif /* NOW_MIRROR_LOG_H */
