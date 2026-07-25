/*
 * commands68.h - the command.request dispatcher: launch and quit.
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
 * The two commands implemented are a composition over proc68.h, not a
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

/* Dispatches one command.request by name.
 *
 * name    - the request's "name" field, NUL-terminated. May be NULL (then
 *           always unrecognized).
 * target  - the request's args.target string, already extracted and
 *           NUL-terminated by the caller; NULL or "" when the request
 *           carried no target. This module does no JSON scanning of its
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
 *           module emits (a proc68.h `detail` sentence, budgeted at 160
 *           bytes in commands68.c) + JSON punctuation, worst case just
 *           under 260 bytes. 320 bytes is a comfortable floor; anything
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
 * Returns 1 if `name` is one of "launch" or "quit" - `out` is then always
 * NUL-terminated JSON, and `*out_len` (if `out_len` is not NULL) is its
 * length. The ok/error TRUTH of a reply is never sacrificed to make it
 * fit smaller - a shortened reply still says what actually happened, and
 * this module pads out a shortening exactly once, using text that will
 * always fit if the envelope itself fits, rather than gradually racing
 * the buffer with a longer and longer fallback chain.
 *
 * Returns 0 if `name` names neither command - `out` is left untouched, so
 * the caller's own unknown-command builder can write into the same
 * buffer without this module having partially filled it with something
 * whose "id" or shape might not match what the caller is about to send.
 */
int now68k_commands_dispatch(const char *name, const char *target, long id,
                              char *out, long cap, long *out_len);

#endif /* NOW68K_COMMANDS68_H */
