/*
 * commands68.h - the command.request dispatcher: help, launch, quit and
 * vprobe.
 *
 * `vprobe` is the odd one and its shape is documented where it is
 * implemented (vprobe68.h). Two things about it belong here: its reply is
 * a row ARRAY rather than a sentence, which is why
 * NOW68K_COMMAND_RESULT_CAP grew below; and like `help` it answers from
 * now68k_commands_dispatch directly, because an N68CmdResult holds two
 * rows and a probe produces sixteen. The console still reaches it through
 * now68k_commands_run (the delegation this file's whole design is for),
 * which hands back the two-row summary - see n68_vprobe_summary and the
 * gap noted at n68_vprobe_render_text.
 *
 * wire68.c owns the wire: framing (frame.h), the outbound queue, and
 * scanning a control payload's envelope (json_scan.h's "type"/"id"
 * reads). This module owns what a command DOES once wire68.c has pulled a
 * name / args.target / id triple out of one command.request - it never
 * calls net.h, never touches frame.h, and never enqueues anything itself;
 * it only fills a caller-supplied buffer with a complete command.result
 * JSON object exactly the way wire68.c's own handle_command_request()
 * already builds one for the unknown-command case (see that function and
 * send_command_result_unknown's fallback text in wire68.c).
 *
 * Every name this module does not recognize is still wire68.c's job: the
 * contract is explicit that an unknown command name is answered
 * ok=false/"unknown-command", NEVER a protocol error - "that is what keeps
 * commands additive" (CommandRequest.name doc, contract/asyncapi.yaml).
 * This module's return value is the additivity seam: 0 means "not mine,
 * build your own unknown-command reply the way you already do," so a
 * command wire68.c has not wired in yet (or a name from a future contract
 * revision this build predates) falls through exactly as it does today.
 *
 * The one command that is not a composition over proc68.h is `help`, and
 * it is here because the OTHER side has no command list. The contract's
 * consoles are dumb shells (CommandRequest.line): they relay the line a
 * human typed and know nothing about which commands exist, because there
 * are now two guests with different tables and a console-side list would be
 * wrong for both. So this Mac answers for itself - three commands, and it
 * says three - and the reply carries a note that everything else answers
 * unknown-command, so a short list reads as a short list rather than as a
 * broken one.
 *
 * The two commands over proc68.h are a composition, not a
 * second copy of its logic: launch is a thin argument-shape check in
 * front of proc_launch_named(); quit mirrors the PowerPC guest's
 * proc_quit_args.c grammar (leading flags, name-is-the-rest-of-the-line)
 * in front of proc_quit_named(), and maps every ProcOutcome to `ok`
 * exactly as proc68.h's own doc comment requires - kProcGone and
 * kProcNotRunning are ok:true, kProcStillRunning is ok:false with a code
 * naming the decline, because a quit that reports success while the
 * target is still running poisons every measurement built on top of it.
 */
#ifndef NOW68K_COMMANDS68_H
#define NOW68K_COMMANDS68_H

#include "n68_cmdresult.h"
#include "n68_vprobe.h"

/* TWO READERS, ONE TABLE.
 *
 * When this header was written the only consumer of a command was the wire,
 * so "dispatch" meant run-and-render-JSON in one call. There is now a second
 * consumer - the interactive console window (conwin.h), where a human at the
 * PowerBook types `launch SimpleText` and wants a sentence, not a JSON
 * object. The seam that keeps them one implementation is now68k_commands_run
 * below: it RUNS a command and hands back what happened (N68CmdResult), and
 * the two renderers in n68_cmdresult.c turn that into either contract bytes
 * or console text.
 *
 * now68k_commands_dispatch is unchanged for its callers - it is now exactly
 * run + n68_cmdresult_render_json - so wire68.c did not have to move, and
 * the additivity contract below still holds verbatim. Adding a command means
 * adding one case to now68k_commands_run and NOTHING else: it appears on the
 * wire and in the console at the same moment, which is the property this
 * split exists to buy.
 *
 * TWO commands do not fit that seam and answer inside dispatch instead:
 * `help` (a row per command) and `ps` (a row per process). An N68CmdResult
 * holds ONE row, so neither could pass through it, and widening the struct
 * to a row array to preserve the shape would cost this guest's 384 KB
 * partition more than the property is worth here. What makes the exception
 * safe is that neither owns an implementation: help renders k_docs, which
 * the console renders too, and ps renders proc_list_rows(), which the
 * console and process.listing also render. Anything with a SINGLE row's
 * worth to say goes through now68k_commands_run, and a third exception
 * should be argued for, not assumed (docs/command-parity.md). */

/* THE size of a command.result on this guest, stated once, here, for both
 * the code that BUILDS one and the code that SENDS it.
 *
 * It was stated three times instead, in two different units, and the
 * smallest won. This module's doc below documented a 320-byte floor for
 * the caller's buffer; wire68.c's handle_command_request gave it 512, so
 * every reply built correctly; and the outbound slot that reply then had
 * to fit was 160, sized by a comment reading "hello (~110), ping (~30),
 * or an error reply (~95)" - true when this guest had no commands at all
 * and never revisited when launch and quit arrived.
 *
 * On the 180c (2026-07-25) `launch` of a name not on the disk built a
 * perfectly good 166-byte reply and had it dropped by the 160-byte slot.
 * The host waits forever for a command.result the contract promises will
 * always come, and the guest logged only "outbound queue full", which was
 * not even the right reason. Both numbers now come from here, and
 * wire68.c static-asserts that its slot can hold one.
 *
 * 512 rather than 320: the floor is what still produces a TRUTHFUL reply
 * via the compact fallback, not what fits a whole one. Sized for the
 * longest sentence proc68.h can hand back (kDetailCap, 160) inside its
 * JSON envelope, with room left so the next command's message is not
 * silently shortened the day it is added.
 *
 * 1024 RATHER THAN 512, since `vprobe`. A command.result carrying a row
 * ARRAY is a different size class from one carrying a sentence, and it
 * cannot page: the contract gives command.result no cursor, so a table
 * either fits one frame or is not sent. vprobe's worst case is
 * NOW68K_VPROBE_JSON_MAX (n68_vprobe.h), asserted against this number
 * below and pinned there by seventeen rows of eighteen and thirty bytes -
 * so growing the table past what the wire can carry fails the build here
 * rather than vanishing on the 180c the way the 166-byte launch reply
 * did. 1024 is also exactly NOW68K_CONTROL_SEND_CAP, which is the ceiling
 * this can reach without widening the wire's own slots; wire68.c asserts
 * that relationship in the other direction.
 *
 * The cost is one 512-byte stack frame: wire68.c's handle_command_request
 * declares its reply buffer at this size, and that function is reachable
 * from a pumped nested dispatch (see proc68.c's `pumping` guard, which
 * bounds that depth). */
#define NOW68K_COMMAND_RESULT_CAP 1024

/* Below this, a reply still comes back and is still true, but the compact
 * fallback starts eating the message - the caller learns THAT something
 * failed and not what. The doc below calls this "a comfortable floor";
 * this is that sentence as a number a compiler can check. */
#define NOW68K_COMMAND_RESULT_FLOOR 320

_Static_assert(NOW68K_COMMAND_RESULT_CAP >= NOW68K_COMMAND_RESULT_FLOOR,
               "a command.result buffer below the floor silently shortens "
               "every message it cannot fit");

/* vprobe's table has no compact fallback and no page after it: if the
 * whole row array does not fit, n68_vprobe_render_json returns nothing and
 * the command answers ok:false instead of measuring. This is the assert
 * that keeps that unreachable. */
_Static_assert(NOW68K_COMMAND_RESULT_CAP >= NOW68K_VPROBE_JSON_MAX,
               "a command.result buffer too small for a full vprobe table - "
               "raise this cap and NOW68K_CONTROL_SEND_CAP together, or "
               "take a row out of the probe");

/* Dispatches one command.request by name.
 *
 * name    - the request's "name" field, NUL-terminated. May be NULL (then
 *           always unrecognized).
 * target  - the request's args.target string, already extracted and
 *           NUL-terminated by the caller; NULL or "" when the request
 *           carried no target. A CONSOLE sends no args at all: it sends
 *           the envelope's `line` (the raw text a human typed after the
 *           command name), and wire68.c hands that over in this same
 *           parameter, because for every command this module serves the
 *           argument IS the whole rest of the line - launch's and quit's
 *           target, help's topic. The grammar inside it is parsed here,
 *           which is the point of the contract's two-callers rule: the
 *           machine that serves the verb owns its grammar. This module does no JSON scanning of its
 *           own - it takes one plain string in, the same shape
 *           proc_quit_args.c takes on the PowerPC side (now/guest/src/
 *           proc_quit_args.c, branch thread/guest-quit-command), which is
 *           what lets that file's grammar be mirrored here verb for verb
 *           instead of re-derived against a JSON payload.
 * id      - the request's id, echoed into the reply verbatim (CommandResult
 *           schema: "id: Echoes the request id").
 * out/cap - buffer for the complete, NUL-terminated command.result JSON
 *           object. Sized for the widest reply this module ever builds:
 *           envelope (~40 bytes) + the longest error/output text this
 *           module emits - a proc68.h `detail` sentence budgeted at 160
 *           bytes in commands68.c, or help's whole command list, which
 *           measures ~260 - plus JSON punctuation, worst case just
 *           under 300 bytes. 320 bytes is a comfortable floor; anything
 *           at or above ~120 bytes still gets a complete, truthful reply
 *           via this module's compact-fallback path (see commands68.c),
 *           just with a shorter message. Below that floor a build can
 *           fail outright - see the return-value note below. One byte of
 *           `cap` is always reserved for the NUL terminator, so a full
 *           `cap`-byte reply is never attempted - see out_len below.
 * out_len - OUT. May be NULL if the caller has no use for it. When this
 *           function returns 1, `*out_len` is set to the number of bytes
 *           written to `out` before its NUL terminator - the same `pos`
 *           this module builds the reply with internally, handed back so
 *           the caller can enqueue (out, *out_len) exactly the way
 *           wire68.c's own send path already does for every other reply,
 *           instead of recovering the length with strlen(out). `out` is
 *           NUL-terminated whenever this function returns 1, including
 *           the (should-not-happen-at-the-recommended-cap) case where
 *           even the compact fallback did not fit `cap` - there `out[0]`
 *           is '\0' and `*out_len` is 0, and the caller must treat that
 *           as nothing-to-send, the same way wire68.c's own builders
 *           already treat a failed now68k_fmt_append_* chain. When this
 *           function returns 0, `*out_len` is left untouched.
 *
 * Returns 1 if `name` is one of "help", "launch", "quit" or "vprobe" -
 * `out` is then always
 * NUL-terminated JSON, and `*out_len` (if `out_len` is not NULL) is its
 * length. The ok/error TRUTH of a reply is never sacrificed to make it
 * fit smaller - a shortened reply still says what actually happened, and
 * this module pads out a shortening exactly once, using text that will
 * always fit if the envelope itself fits, rather than gradually racing
 * the buffer with a longer and longer fallback chain.
 *
 * Returns 0 if `name` names none of them - `out` is left untouched, so
 * the caller's own unknown-command builder can write into the same
 * buffer without this module having partially filled it with something
 * whose "id" or shape might not match what the caller is about to send.
 */
/* The commands this Mac serves, and what they do - ONE list, rendered
 * twice. wire68.c answers `help` over the wire from it; conwin.c prints it
 * in the console window. It is published rather than static because the
 * alternative is two hand-written lists that agree until the day someone
 * adds a command to one of them, and then quietly disagree about what this
 * machine can do. docs/command-parity.md is the rule this serves.
 *
 * Terminated by a NULL name. Console-local verbs (help's own `clear`, `ps`)
 * are NOT here: they are not commands the wire serves, and putting them in
 * this list would make the wire's help advertise things it cannot do. */
typedef struct {
    const char *name;
    const char *summary;
    const char *usage;
} N68CommandDoc;

/* Runs `vprobe` and lends the caller the table it filled, or NULL if the
 * probe refused (the reason lands in `why`).
 *
 * The console needs the WHOLE table, not the two-row summary an
 * N68CmdResult can carry - a measurement command whose console face shows
 * two of seventeen rows is a capability reachable from one face and
 * summarised on the other, which docs/command-parity.md does not count as
 * reachable. So the console renders the same table the wire does, through
 * n68_vprobe_render_text.
 *
 * LENT, not owned: the pointer is commands68.c's single static table (one
 * instance, because 820 bytes is too much for a stack frame the command
 * path can re-enter). It is valid until the next vprobe run, which is all
 * any caller needs, and vprobe68_run refuses re-entry so two probes can
 * never be filling it at once. */
const N68VProbeTable *now68k_commands_vprobe(char *why, long why_cap);

const N68CommandDoc *now68k_commands_docs(void);

int now68k_commands_dispatch(const char *name, const char *target, long id,
                              char *out, long cap, long *out_len);

/* Runs one command by name and fills `res` with what happened - no
 * formatting, no `id`, nothing wire-shaped.
 *
 * Same additivity seam as now68k_commands_dispatch above, and the same
 * meaning for the return value: 1 if `name` is one of "launch" or "quit"
 * (then `res` is fully populated, ok or not), 0 if it is neither - and 0 is
 * NOT an error, it is "not mine". Each caller answers an unrecognized name
 * in its own vocabulary: wire68.c builds the contract's
 * ok=false/"unknown-command" reply, and conwin.c prints one line saying so.
 * Neither has to know about the other.
 *
 * `res` is zeroed before the command runs, so a partially-filled result can
 * never survive from a previous call. It may not be NULL; `name` may be
 * (then always unrecognized). `target` follows now68k_commands_dispatch's
 * rules exactly - the args.target string, already extracted, or NULL/"".
 *
 * NOT free of side effects and not free of TIME: `launch` walks the catalog
 * for up to proc68.h's launch-search budget, and `quit` waits out its
 * confirmation window. A caller inside an event loop must pump the wire
 * around this call the way main.c pumps around MenuSelect - see conwin.c. */
int now68k_commands_run(const char *name, const char *target,
                         N68CmdResult *res);

#endif /* NOW68K_COMMANDS68_H */
