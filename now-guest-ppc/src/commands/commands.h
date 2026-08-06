#ifndef NOW_COMMANDS_H
#define NOW_COMMANDS_H

/* The guest's command table — the closed set declared in the contract's
   x-commands registry. One implementation, two invocation paths: the wire
   dispatches host requests through now_command_run (JSON), and the guest's
   own console gathers the same data directly. */

/* How much room a command.result needs, stated ONCE because the two
   callers are the two faces and a reply that fits one and not the other is
   a capability that works on one face only.

   It was 3072 in wire.c and 512 in console_model.c, and neither number
   said so. Any verb answering more than 512 bytes was therefore truncated
   mid-JSON for anyone typing it at the machine — parsed as nothing, and
   reported as "command failed" — while the same verb answered the host in
   full. That is AGENTS.md's "state a limit once, where both sides read
   it", one guest below where it usually applies. */
enum { kNowCommandResultCap = 3072 };

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

/* --- processes, as flat rows (the `ps` command's data layer) ------------ */

#define kProcMaxRows 64

typedef struct {
    char name[32];       /* the process name */
    char detail[64];     /* kind, size, and whether it is frontmost */
} ProcRow;

/* Walks this machine's Process Manager into `rows`, one per readable
   process, and returns the count. The wire's `ps` serializes these to
   [name, detail] pairs; the guest console renders them directly. This is
   the flat, unpaged cousin of wire.c's serve_process_list, which carries
   PSNs and pages because the drive verbs need to name a process; ps names
   nothing, so it needs neither. */
int now_process_gather(ProcRow *rows, int max);

#endif
