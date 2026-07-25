#ifndef NOW_PROC_QUIT_ARGS_H
#define NOW_PROC_QUIT_ARGS_H

/* `quit`'s argument line, parsed once for both callers.
   ------------------------------------------------------------------
   `quit` names a process the way `launch` names an application: the
   NAME IS THE WHOLE REST OF THE LINE, so spaces need no quoting, and
   any flag is therefore LEADING. That is not a style choice — a
   trailing flag is indistinguishable from the last word of a process
   name, and process names have spaces in them ("Apple File Security",
   "NetPresenz Setup").

   One parser, not two dialects: the guest console and the host's
   command.request both land here, exactly as now_software_launch owns
   launch's dialect. The 68K client mirrors this file, not a re-derived
   grammar.

   It is Toolbox-free on purpose, so the host cc compiles it and the
   bounds get watched failing here rather than discovered on the
   PowerBook (guest/tests/proc_quit_args_test.c). */

/* A classic process name is a Str31: 31 characters plus the NUL. A
   longer argument cannot match any process, and the parser says so
   rather than silently comparing a truncation. */
#define kProcQuitNameMax 32

/* The confirmation wait. A cooperative quit is not instant — the target
   only sees the Apple Event when the Process Manager next schedules it —
   so the default gives it several seconds of yielded time. The ceiling
   is what keeps a wire-served quit inside the host's 75 s idle timeout
   with room to spare; runCommand arms no watchdog of its own. */
#define kProcQuitWaitDefault 6
#define kProcQuitWaitMax 20

typedef struct {
    char name[kProcQuitNameMax]; /* the process name to match, never "" */
    int all;                     /* --all: quit EVERY match, not refuse */
    int confirm;                 /* 0 after --no-wait: send, do not verify */
    int wait_secs;               /* seconds to wait for the process to go */
} ProcQuitArgs;

/* Parses `arg` (everything after the command name) into `out`. Returns 1
   on success; on failure returns 0 and writes a one-line reason into
   `msg` (bounded by `cap`, NUL-terminated). `msg` may not be NULL. */
int now_proc_quit_parse(const char *arg, ProcQuitArgs *out,
                        char *msg, long cap);

#endif /* NOW_PROC_QUIT_ARGS_H */
