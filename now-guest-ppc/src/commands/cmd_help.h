#ifndef NOW_CMD_HELP_H
#define NOW_CMD_HELP_H

/* The command documentation table - one table, three readers.
 *
 * The host console used to carry its own copy of this, which made it a
 * console that knew what was installed on the far machine. There are now
 * TWO guests with different command tables (this one and NOW-68K), so a
 * host-side list is wrong for both; the host asks instead, with the `help`
 * command, and renders what comes back. That makes this table the answer
 * to a wire request as well as the source of this Mac's own console help.
 *
 * Readers:
 *   - commands.c    serves `help` over the wire (the WIRE rows only).
 *   - console_model.c   this Mac's own console help (every row).
 *   - now-guest-ppc/tests/cmd_help_test.c   checks the table's shape natively.
 *
 * VOICE: every summary and detail line is spoken BY this machine ABOUT
 * itself - "this Mac", never "the other Mac". That reads correctly on both
 * consoles, because the host renders the reply under a prompt labelled
 * with the guest's own name: the machine you are addressing is answering.
 */

typedef struct {
    const char *name;
    /* 1 = served over the wire by now_command_run, and therefore declared
       in the contract's x-commands. 0 = a verb only this Mac's own console
       has (put, mv, trash, ..., and its two local affordances). The host
       must never be offered a 0 - it would send something this Mac answers
       "unknown-command". */
    unsigned char wire;
    const char *summary;         /* one line, no trailing period */
    const char *usage;           /* "ls [path]" - never NULL */
    /* Extra lines, in display order; NULL-terminated. May be NULL. */
    const char *const *detail;
} NowCommandDoc;

/* The table, terminated by a NULL `name`. */
extern const NowCommandDoc kNowCommandDocs[];

/* One doc by name, or NULL. */
const NowCommandDoc *now_command_doc(const char *name);

/* How many docs the table holds (excluding the terminator). */
int now_command_doc_count(void);

#endif
