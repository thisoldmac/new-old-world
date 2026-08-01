#ifndef NOW_MACH_REPLY_H
#define NOW_MACH_REPLY_H

/* The command.result envelope, as every other command in this guest
   writes it: output.<name> is an array of [label, value] rows (the
   contract's x-rowArray), and a failure is ok:false with a code and a
   sentence.

   A local copy of the act plane's row builder rather than a shared one,
   deliberately and narrowly: act_cmds.c's version is static inside a
   file this thread does not own, and exporting it would be an edit to a
   file another agent is live across. Two callers is not yet a library. */

typedef struct {
    char rows[1024];
    long used;
    int  overflow;
} NowMachRows;

void now_mach_rows_reset(NowMachRows *r);
void now_mach_row(NowMachRows *r, const char *label, const char *value);
void now_mach_rowf(NowMachRows *r, const char *label, const char *fmt,
                   unsigned long v);

void now_mach_reply_rows(char *out, long cap, long id, const char *name,
                         const NowMachRows *r);
void now_mach_reply_error(char *out, long cap, long id, const char *code,
                          const char *message);

#endif /* NOW_MACH_REPLY_H */
