#ifndef NOW_INPUT_ARGS_H
#define NOW_INPUT_ARGS_H

/* input_args.h - the deciding half of the input plane, with no Toolbox
   in it.
   ------------------------------------------------------------------
   Four verbs live in src/input/: `mouseloc` reads where the pointer
   is, `key` posts one keystroke, `script` runs one AppleScript, and
   `aesend` sends one of four core Apple Events to a named process.
   Every choice any of them makes
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

/* ---- key -------------------------------------------------------------

   ONE KEYSTROKE, AND NO MODIFIERS - and the second half of that sentence
   is the whole design, so it is stated before the arguments are.

   `textset` already writes text into an addressed element, directly, by
   the Dialog Manager's or TextEdit's own setter. It reaches further than
   a keystroke in one direction (it does not need the element focused, or
   the application frontmost) and not at all in the other: a dialog that
   only answers keystrokes never sees it, and there is no text to set for
   Return, Escape or Tab. `key` is the other mechanism, not a better one.

   THE MODIFIER WALL, which is a NOW fact and inverts the usual posture
   between the two ISAs:

     - The Event Manager takes an event's modifiers from the queue
       ELEMENT, not from the message. `PostEvent` gives a caller no
       handle on that element; `PPostEvent` hands it back, which is how
       upstream's guest stamped `evtQModifiers` and got a command key.
     - `PPostEvent` is CALL_NOT_IN_CARBON (Events.h: "CarbonLib: not
       available"). `PostEvent` is in CarbonLib. NOW's application is
       Carbon. So this guest can queue a keystroke and CANNOT say what
       was held down while it was typed.
     - The resident half is 68K and not Carbon, and it does call
       PPostEvent - that is how the act plane posts its own press
       (ext/src/now_ext_act.c, docs/resident-components.md). A modified
       keystroke is therefore reachable from NOW, but only through the
       act plane's cell and an armed extension. It is not reachable from
       the application, and this verb lives in the application.

   So a `mods` argument is REFUSED here rather than dropped. That is the
   defect upstream paid for and wrote down: an act that silently lost a
   command modifier typed a literal character into a document and
   answered ok. A caller that asked for Command-N and got `n` has been
   told something false; a caller that asked for Command-N and was
   refused knows to use `menuact`, which needs no modifier, draws no
   menu, and is addressed by identity rather than by a shortcut.

   `mods: 0` is accepted. A caller that says "no modifiers" is asking for
   what this verb does.

   WHAT IT CAN DO, which is the reason it exists: Return, Enter, Escape,
   Tab, Space, Delete, the four arrows and the navigation cluster, and
   any plain character - each posted with both halves of the message a
   real keystroke carries. The `code` half matters even unmodified: the
   Menu Manager matches shortcuts on the virtual KEY CODE and not the
   character (upstream: `key {char:'n'}` opened New in SimpleText and
   silently no-op'd in the Finder), so a verb that could only ever send a
   character would be shipping that same near-miss one layer down. */
enum {
    kNowKeyCodeMax = 127,      /* a virtual key code is 7 bits */
    kNowKeyCharMax = 255,      /* one byte of the message's low half */
    kNowKeyNameMax = 16
};

typedef enum {
    kNowKeyOk = 0,
    kNowKeyNoKey,          /* neither name, code nor char was sent */
    kNowKeyUnknownName,
    kNowKeyCodeRange,
    kNowKeyCharRange,
    kNowKeyModifiers       /* mods were asked for; see the wall above */
} NowKeyStatus;

/* One resolved keystroke. `code_known` / `char_known` are 0 when this
   half could not be derived and is being sent as 0 - reported on the
   wire rather than smoothed over, because an application that matches on
   the half we did not have will not respond and the caller needs to be
   able to see why. */
typedef struct {
    int code;
    int ch;
    int code_known;
    int char_known;
} NowKeyRequest;

/* The named keys, for the half of this verb `textset` cannot express at
   all. `name` is matched exactly and in lower case; the table is the
   standard Macintosh virtual key codes (P-DOC: Inside Macintosh: Text,
   "Keyboard Virtual Key Codes"), cross-checked against the one number
   upstream measured on a live machine - `n` is 45 there and 45 here.

   Returns 1 and fills both halves, or 0 for a name not in the table. */
int now_key_named(const char *name, int *code_out, int *char_out);

/* The character a plain (unshifted, US) press of `code` produces, or 0
   when the code is not one of the character keys. */
int now_key_char_for_code(int code);

/* The virtual key code that produces `ch` on a plain US press, or -1.
   Case-folded: `N` and `n` are the same KEY held with a different
   modifier, and the modifier is exactly what this verb cannot send - so
   the code is right and the character is passed through unchanged, which
   is what makes an upper-case character type correctly anyway (an
   application reads the case out of the message's low half). */
int now_key_code_for_char(int ch);

/* The whole gate one key request passes before anything is queued.
   `name` is the wire's `name` argument or NULL when absent; `code` and
   `ch` are its integer arguments with their own presence flags; `mods`
   likewise.

   Checked in this order deliberately: modifiers first, so a caller that
   asked for Command-something is told the true reason rather than a
   complaint about some other argument it also got wrong. */
NowKeyStatus now_key_check(const char *name,
                           long code, int code_present,
                           long ch, int char_present,
                           long mods, int mods_present,
                           NowKeyRequest *out);

/* The console grammar, which is the same decision from a typed line.

   `key return`, `key n`, `key char 13`, `key code 36`. A bare token one
   character long is that character, because a person typing `key n`
   means the letter and not a key named "n".

   A leading modifier word (cmd, command, option, opt, shift, control,
   ctrl) answers kNowKeyModifiers rather than "unknown key name". A
   person who types `key cmd n` has run into the wall this verb has, and
   the reason for the refusal is worth more than a list of names that
   does not contain the word they typed. */
NowKeyStatus now_key_parse_line(const char *args, NowKeyRequest *out);

/* The Event Manager message for a resolved keystroke: key code in the
   second byte, character in the low byte.

   `unsigned int` and not `unsigned long` ON PURPOSE - the host's long is
   64 bits and this guest's is 32, and this file's opening note says a
   bound written against a long is decorative on one side. int is 32 bits
   on both, and the shift below is watched failing in the native test. */
unsigned int now_key_message(const NowKeyRequest *req);

const char *now_key_status_code(NowKeyStatus status);
const char *now_key_status_message(NowKeyStatus status);

/* ---- script ----------------------------------------------------------

   The source size is upstream's (timbottu/mirror, verb_script), which is
   where it was measured against a real OSA component; it is carried as a
   fact, not re-derived.

   THE RESULT SIZE IS NOT UPSTREAM'S, and the difference is a NOW fact
   rather than a preference. Upstream returned 4096 bytes because its
   guest wrote one newline-terminated line straight to a socket. NOW's
   command.result is assembled in a 3072-byte buffer in
   src/core/wire.c (`char result[3072]`), so a 4096-byte output could
   not be delivered - it would be silently cut by the serializer, at
   whatever byte the buffer ran out, and reported as a whole answer.
   The budget below is stated so that a later change to either number
   fails a test rather than a machine. */
enum {
    kNowScriptSrcMax = 2048,       /* source bytes accepted from the host */
    kNowScriptOutMax = 1024,       /* result bytes returned, PRE-escape */
    kNowScriptEscMax = 2560,       /* the same result, JSON-escaped */
    kNowScriptReplyBudget = 3072,  /* src/core/wire.c's result buffer */
    kNowScriptRowOverhead = 256,   /* envelope + the other rows, generously */
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
