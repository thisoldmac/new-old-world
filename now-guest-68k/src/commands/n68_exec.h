/*
 * n68_exec.h - one typed line in, console text out, with no opinion about
 * who is reading it.
 *
 * THIS FILE EXISTS TO STOP A SECOND CONSOLE FROM BEING WRITTEN.
 *
 * n68_cmdresult.h stopped a second command TABLE: a command produces facts
 * and two renderers turn them into wire bytes or console text. It stops one
 * layer short of the thing a console actually is, though. Deciding that
 * `vprobe` renders its whole table rather than a two-row summary, that `ps`
 * is dispatched here rather than through the one-row seam, that a table verb
 * is asked for BEFORE a one-row verb, that an unrecognized name says
 * "! unknown-command: <name>" - none of that is a renderer. It is a
 * dispatch policy, and until this file it lived inside conwin.c's
 * submit_line(), reachable only by someone standing at the PowerBook.
 *
 * That was fine while the host console was a shell over command.request:
 * the host sent a name and the wire answered from the same table, so the
 * two faces agreed by construction. It stops being fine the moment the host
 * sends a LINE and expects back what this machine would have shown - which
 * is what exec.request is (contract/asyncapi.yaml, the Exec preamble). A
 * remote console rendered from a second dispatch is a remote console that
 * shows something else, and "something else" is invisible until someone
 * sits at both keyboards and compares.
 *
 * So the policy moves here, and BOTH consoles call it:
 *
 *   conwin.c   emits into its N68ConsoleRing and draws the pane
 *   wire68.c   emits into an exec.output frame and sends it
 *
 * Same order of arms, same renderers, same words - because it is the same
 * function. That is not an optimization; it is the acceptance property of
 * the exec plane, and it is why this file is a seam rather than a helper.
 *
 * WHAT STAYS IN conwin.c, and the test for it: anything that acts on the
 * WINDOW rather than on the machine. `clear` empties a scrollback that only
 * exists at the PowerBook; history, scrolling, the echoed "> line" and the
 * edit field are all the same shape. The host has its own scrollback and
 * its own /clear, and a wire that carried "clear" would be one machine
 * reaching into another's view. Same rule the host's own /-verbs follow
 * from the other end (ConsoleModel.LocalVerb): a verb belongs to the side
 * whose pixels it changes.
 *
 * No Toolbox calls and no window state here, which is what lets this file
 * be reached from the wire's dispatch as well as from a WaitNextEvent app.
 */
#ifndef NOW68K_N68_EXEC_H
#define NOW68K_N68_EXEC_H

/*
 * Receives one CR-terminated block of console text.
 *
 * `text` is `length` bytes and is NOT NUL-terminated at that point - it may
 * be an interior slice of a render buffer. The emitter appends its own line
 * terminator, exactly as conwin.c's con_out/con_out_block both do (feed the
 * block, then feed one "\r"), which is why a single callback covers both
 * the one-line and the multi-line callers this file has.
 *
 * Text is MacRoman and is handed over as the guest would have drawn it. An
 * emitter bound for the wire escapes it there (now68k_json_append_escaped);
 * an emitter bound for the screen passes it to QuickDraw unchanged. Neither
 * transcoding belongs here.
 */
typedef void (*N68ExecEmit)(void *ctx, const char *text, long length);

/*
 * Called between the slow arms of a dispatch, or NULL for a caller that
 * must not be re-entered.
 *
 * conwin.c passes wire_idle: a human at the keyboard has just started a
 * command that may walk the catalog or wait out a quit confirmation, and
 * the wire must not die of silence while they do. wire68.c passes NULL,
 * because it IS the wire and pumping from inside its own dispatch would
 * re-enter the read path with a half-served request on the stack.
 *
 * That asymmetry is deliberate and it is the one behavioural difference
 * between the two faces. It costs the wire face nothing that the existing
 * command.request path does not already cost - now68k_commands_dispatch has
 * never pumped either - so exec is no more blocking than the plane it sits
 * beside, and no less.
 */
typedef void (*N68ExecPump)(void);

/*
 * Interprets `line` - the WHOLE line a human typed, verb included - and
 * emits what this machine's console would show for it.
 *
 * `line` may be NULL or empty; both emit nothing and return 1. An empty
 * Return has asked for nothing, which is a thing a console sees constantly
 * and is not a failure (contract: ExecRequest.line).
 *
 * Returns 1 if the line was interpreted (INCLUDING a command that ran and
 * failed - the failure is in the emitted text, where a human can read it),
 * and 0 only if the verb is not one this machine serves. On 0 this function
 * has already emitted "! unknown-command: <name>", so a caller that only
 * renders text can ignore the return value entirely; wire68.c uses it to
 * set exec.result's ok bit and code, because the contract distinguishes
 * "ran and said no" from "no such verb" and a host tool wants to as well.
 *
 * NOT free of TIME. `launch` walks the catalog, `quit` waits out its
 * confirmation window, `vprobe` measures for ~12 seconds. See N68ExecPump
 * above for what each caller does about that.
 */
int now68k_exec_line(const char *line, N68ExecEmit emit, void *ctx,
                     N68ExecPump pump);

/*
 * Splits "verb rest of the line" the way this machine does.
 *
 * Published for ONE caller - conwin.c, which needs the verb to answer its
 * own window-local `clear` before handing everything else here. It is not
 * an invitation to split a line anywhere else, and in particular the HOST
 * must never do it: that split is a grammar, the grammar belongs to the
 * machine that serves the verb, and the host having its own copy of it is
 * precisely the leak the exec plane closes (contract: ExecRequest.line).
 *
 * A name longer than `name_cap` is consumed whole rather than spilling into
 * the target, so a typo stays an unrecognized name instead of quietly
 * becoming a different command with a strange argument.
 *
 * Returns a pointer into `line`, at the first byte after the verb and its
 * following whitespace.
 */
const char *now68k_exec_split(const char *line, char *name, int name_cap);

#endif /* NOW68K_N68_EXEC_H */
