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

/* One line. `area` is a short tag ("wire", "files", "browse") so a log
   can be read by subsystem. */
void now_log(LogLevel level, const char *area, const char *fmt, ...);

/* The last `count` lines, newest last, for `tail`. Returns how many
   were written into `out`, which must hold count * kLogLineMax. */
enum { kLogLineMax = 120, kLogKept = 200 };
int now_log_tail(int count, char *out, long cap);

/* Where this launch is writing, for the console to name. */
const char *now_log_path(void);

#endif /* NOW_LOG_H */
