#ifndef NOW_LOG_H
#define NOW_LOG_H

#include <Carbon.h>

/* The guest's log.
   ------------------------------------------------------------------
   One file per launch in a "now-logs" folder beside the application,
   named for the moment it started, plus the last lines kept in memory
   so `tail` costs no disk.

   Why a file at all, on a machine this slow: the interesting failures
   here are the ones that leave nothing behind. A Type 3 takes the
   window, the status line and every in-memory buffer with it, and the
   only thing that survives is what already reached the disk. Three
   separate bugs this month were diagnosed by inventing a throwaway
   flight recorder on the spot; this is that, kept.

   What NOT to log: anything in a per-chunk path. A transfer moves
   thousands of chunks, and an instrument that costs a disk write per
   chunk eats the thing it is measuring — the File Sharing panel taught
   that lesson expensively. Log the shape of an event, not its
   heartbeat: begun, ended with a count, refused with a reason. */

typedef enum {
    kLogInfo = 0,                     /* it happened */
    kLogWarn,                         /* it went wrong and continued */
    kLogError                         /* it went wrong and stopped */
} LogLevel;

/* Opens this launch's file. Safe to call once at startup; failure is
   silent and leaves logging as a no-op, because a machine that cannot
   write a log must still be able to run. */
void now_log_open(void);
void now_log_close(void);

/* Disk persistence, on a switch the Logs module owns. The in-memory ring
   is always live; this only governs whether a line also reaches the
   now-logs file. Turning it on opens a fresh per-launch file; turning it
   off closes the current one. Idempotent. now_log_disk_on reports the
   actual state (a failed open leaves it off), so the switch stays honest. */
void now_log_set_disk(Boolean on);
Boolean now_log_disk_on(void);

/* Number of recognized launch logs retained in the owned folder, including
   the current file. Values outside the shared 1..100 contract become the
   default 10. Changing it prunes immediately when a log folder is open. */
void now_log_set_retention(short keep);
short now_log_retention(void);

/* One line. `area` is a short tag ("wire", "files", "browse") so a log
   can be read by subsystem. */
void now_log(LogLevel level, const char *area, const char *fmt, ...);

/* Force the pending log to the platter now. A kLogInfo line otherwise
   sits in the disk cache and a crash loses it; call this after a line
   that might be the last one before a risky step (teardown), so the log
   ends ON the stage it did not survive. No-op when disk logging is off.
   now_log already does this for kLogError. */
void now_log_flush(void);

/* The last `count` lines, newest last, for `tail`. Returns how many
   were written into `out`, which must hold count * kLogLineMax.
   kLogKept is the in-memory scrollback the Logs module dumps; it is large
   because that page is the reason to keep more than a `tail` of history. */
enum { kLogLineMax = 120, kLogKept = 2000, kLogTailMax = 48 };
int now_log_tail(int count, char *out, long cap);

/* The ring as a scrollback for the Logs page: how many lines are held,
   and the i-th line OLDEST-first (i in [0, now_log_count)). The returned
   pointer is valid until the next now_log call. */
int now_log_count(void);
const char *now_log_line(int index);

/* Where this launch is writing, for the console to name. */
const char *now_log_path(void);

#endif /* NOW_LOG_H */
