#ifndef NOW_COMMANDS_H
#define NOW_COMMANDS_H

/* The guest's command table — the closed set declared in the contract's
   x-commands registry. One implementation, two invocation paths: the wire
   dispatches host requests through now_command_run (JSON), and the guest's
   own console gathers the same data directly. */

/* Runs `name` and writes a complete command.result JSON (echoing `id`) into
   out. `request_json` is the raw command.request (for args; may be NULL).
   Unknown names produce ok=false / "unknown-command" — a result, never a
   protocol error; that is what keeps the command set additive. */
void now_command_run(const char *name, const char *request_json, long id,
                     char *out, long cap);

/* --- machine identity --------------------------------------------------- */

/* Writes this machine's name — what the other side calls it on screen —
   into out (NUL-terminated, at most cap - 1 characters). Never empty. */
void now_machine_name(char *out, long cap);

/* --- gestalt, as structured rows (the data layer both paths share) ------ */

#define kGestaltMaxRows 48

typedef struct {
    char group[12];      /* snapshot | cpu | memory | os | network | hw */
    char label[28];
    char value[56];
} GestaltRow;

/* Gathers the whole machine snapshot into `rows` (each tagged with a group).
   Returns the row count. The wire serializes these to grouped JSON; the
   guest console renders them directly. */
int now_gestalt_gather(GestaltRow *rows, int max);

/* The group names, in display order for --full (snapshot is the default view
   and is intentionally excluded from --full). NULL-terminated. */
extern const char *const kGestaltFullGroups[];

#endif
