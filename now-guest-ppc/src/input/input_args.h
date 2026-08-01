#ifndef NOW_INPUT_ARGS_H
#define NOW_INPUT_ARGS_H

/* input_args.h - the deciding half of the input plane, with no Toolbox
   in it.
   ------------------------------------------------------------------
   Three verbs live in src/input/: `mouseloc` reads where the pointer
   is, `script` runs one AppleScript, and `aesend` sends one of four
   core Apple Events to a named process. Every choice any of them makes
   before touching the machine is in this file, so it compiles on the
   host cc and its bounds get watched failing in
   now-guest-ppc/tests/input_args_test.c rather than discovered on a
   PowerBook. That is the same split peek_oracle.c, scene_build.c,
   files_pull.c and now_act_guard.c already use, and it is the only
   reason any of this is testable at all.

   A NOTE ON WIDTHS, because it has already cost this repo a mutation.
   The host's `long` is 64 bits and this guest's is 32, so a guard
   written against a `long`'s range is decorative on one side and load
   bearing on the other - a mutation of one passed a native run today.
   Nothing below guards a width. Every bound here is a small decimal
   number compared against an `int`, which is 32 bits on both, and the
   one place a 32-bit wire value is unavoidable (a process serial) is
   taken as two `unsigned long`s and never arithmetic. */

/* ---- script ----------------------------------------------------------

   Sizes are upstream's (timbottu/mirror, verb_script), which is where
   they were measured against a real OSA component; they are carried as
   facts, not re-derived. */
enum {
    kNowScriptSrcMax = 2048,       /* source bytes accepted from the host */
    kNowScriptOutMax = 4096,       /* result bytes returned, pre-escape */
    kNowScriptWrapExtra = 64,      /* room for the `with timeout` wrapper */
    kNowScriptWrapMax = kNowScriptSrcMax + kNowScriptWrapExtra,
    kNowScriptMinMs = 500,
    kNowScriptDefaultMs = 15000,
    kNowScriptMaxMs = 60000        /* hard ceiling; the guest is serial */
};

typedef enum {
    kNowScriptOk = 0,
    kNowScriptNoSource,
    kNowScriptSourceTooLong,
    kNowScriptSearches
} NowScriptStatus;

/* The prepared script, ready to hand to OSADoScript.

   BIG, AND DELIBERATELY SO - which is why every caller must make it
   static rather than a local. Upstream's own comment on this function
   reads "static, never locals - see the fat-frame finding": an OSA call
   with a fat stack frame under it was one of this family's real
   failures, and 2 KB of source plus its wrapper is exactly that frame.
   The type is named rather than inlined so the rule has somewhere to
   live. */
typedef struct {
    char text[kNowScriptWrapMax + 1];
    int  length;        /* bytes in text, excluding the terminator */
    int  timeout_ms;    /* clamped */
    int  timeout_secs;  /* what the wrapper asks for, rounded up */
    int  wrapped;       /* 1 if the `with timeout` wrapper is in text */
    int  lines;         /* line count, for the CR conversion's own test */
} NowScriptRequest;

/* Clamps a requested timeout into [kNowScriptMinMs, kNowScriptMaxMs].
   `present` is 0 when the caller sent no timeoutMs at all, in which case
   `requested` is ignored and the default is used - a caller that sent
   nothing and a caller that sent the default are the same request, but a
   caller that sent 0 asked for something and gets the floor. */
int now_script_clamp_ms(long requested, int present);

/* 1 if `source` contains a whole-disk Finder search.

   THE ONE HAZARD IN THIS FILE THAT IS ABOUT REAL HARDWARE. A Finder
   script using `entire contents` wedged a real machine for about twelve
   minutes (lab finding 2026-07-05, carried in docs/mirror-knowledge.md
   and docs/mirror-perceive-plane.md, which says every script must be
   scoped to a window the Finder is already showing and that none of them
   may search). A refusal here is worth more than a comment: the wedge
   is not recoverable from this side, so there is no error path that
   could report it after the fact.

   Matched case-insensitively and across any run of spaces or tabs, so
   `Entire  Contents` does not walk past. Not a security boundary and it
   does not pretend to be one - a caller who wants the search can spell
   it some other way, and this is aimed at the person who did not know
   the hazard, not at the person routing around it. */
int now_script_is_whole_disk_search(const char *source, int length);

/* Prepares one script request. `source` and `length` are the wire's
   `source` argument as extracted (length < 0 means the key was absent);
   `timeout_ms` and `timeout_present` feed now_script_clamp_ms.

   On kNowScriptOk, `out` carries the source with the timeout wrapper
   applied where it fits, and EVERY newline converted to a carriage
   return. The CR conversion is not cosmetic: classic AppleScript's
   line terminator is CR, and a source arriving with LF endings from a
   modern host parses as one very long line. */
NowScriptStatus now_script_prepare(const char *source, int length,
                                   long timeout_ms, int timeout_present,
                                   NowScriptRequest *out);

/* The wire's error code and message for a preparation failure. */
const char *now_script_status_code(NowScriptStatus status);
const char *now_script_status_message(NowScriptStatus status);

/* Was this run cut off at the deadline?

   Three signals, because no one of them is sufficient. `active_fired` is
   the OSA active procedure having seen the clock pass; `osa_err` is
   what OSADoScript returned; `hit_deadline` is the clock read after the
   call. A `with timeout` cap surfaces as a GENERIC OSA error wrapping
   errAETimeout rather than as errAETimeout itself, which is why an error
   that also reached the deadline counts - and why a SUCCESS that
   happened to finish on the deadline does not. */
int now_script_timed_out(int active_fired, int osa_err, int hit_deadline);

/* ---- aesend ----------------------------------------------------------

   A CLOSED VOCABULARY OF FOUR, not a class/id pipe. The wire names an
   op; it does not name an event class and an event id. That is the
   whole difference between a row whose arguments bound what it does and
   one whose arguments do not, and this plane has already refused the
   second shape once. Each of the four has an effect that can be stated
   in one line, which is the test a new one would have to pass.

   The four names are upstream's four-character mnemonics rather than
   longer words, because the ported probe's whitelist and its
   off-whitelist refusal check are written against them and a rename
   here would cost the comparison for nothing. */
typedef enum {
    kNowAeOpNone = 0,
    kNowAeOpQuit,      /* quit - ask the application to quit */
    kNowAeOpOpenApp,   /* oapp - the no-document open event */
    kNowAeOpOpenDoc,   /* odoc - open one document */
    kNowAeOpPrintDoc   /* pdoc - print one document */
} NowAeOp;

enum { kNowAePathMax = 256 };      /* a classic path is a Str255 */

typedef enum {
    kNowAeOk = 0,
    kNowAeNoEvent,
    kNowAeUnknownEvent,
    kNowAeNoSerial,
    kNowAeNoProcess,
    kNowAeSelf,
    kNowAeNoPath,
    kNowAePathTooLong
} NowAeStatus;

/* Maps a wire name to an op, or kNowAeOpNone. Exact match only: a
   truncated or padded name is not a near miss to be forgiven, it is a
   name this plane does not serve. */
NowAeOp now_ae_op_from_name(const char *name);

/* The op's wire name, or "" for kNowAeOpNone. */
const char *now_ae_op_name(NowAeOp op);

/* 1 for the two ops that carry a document. */
int now_ae_op_needs_document(NowAeOp op);

/* 1 if this serial names no process at all. (0, 0) is kNoProcess by
   definition, so it is refused here rather than sent and left to come
   back as procNotFound - the answer is the same and this one costs no
   Apple Event. */
int now_ae_serial_is_none(unsigned long hi, unsigned long lo);

/* 1 if the two serials are the same process.

   Used to refuse addressing ourselves, which matters for exactly one
   op and matters a lot: a quit event to our own serial takes the guest
   down mid-reply, so the caller sees a dropped connection where the
   truthful answer is "you asked me to quit myself". The comparison is
   here rather than beside GetCurrentProcess so it can be watched
   failing. */
int now_ae_serial_same(unsigned long a_hi, unsigned long a_lo,
                       unsigned long b_hi, unsigned long b_lo);

/* The whole gate one aesend request passes before any descriptor is
   built. `event` is the wire's `event` argument or NULL when absent;
   `serial_present` is 0 unless BOTH serialHi and serialLo were sent;
   `path_length` is the `path` argument's length, or negative when the
   key is absent. `self_*` is this process's own serial. */
NowAeStatus now_ae_check(const char *event, int serial_present,
                         unsigned long hi, unsigned long lo,
                         unsigned long self_hi, unsigned long self_lo,
                         int path_length, NowAeOp *op_out);

const char *now_ae_status_code(NowAeStatus status);
const char *now_ae_status_message(NowAeStatus status);

#endif /* NOW_INPUT_ARGS_H */
