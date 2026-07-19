#ifndef NOW_COMMANDS_H
#define NOW_COMMANDS_H

/* The guest's command table — the closed set declared in the contract's
   x-commands registry. One implementation, two invocation paths: the wire
   dispatches host requests here, and the guest's own console (stage two)
   calls the same table locally. */

/* Runs `name` and writes a complete command.result JSON (echoing `id`) into
   out. Unknown names produce ok=false / "unknown-command" — a result, never
   a protocol error; that is what keeps the command set additive. */
void now_command_run(const char *name, long id, char *out, long cap);

#endif
