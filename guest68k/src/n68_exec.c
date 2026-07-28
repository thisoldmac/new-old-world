/*
 * n68_exec.c - the dispatch policy both consoles run. See n68_exec.h for
 * why it is a file rather than a block inside conwin.c's submit_line().
 *
 * Every function here was moved out of conwin.c verbatim except for one
 * mechanical substitution: con_out(s) became emit(ctx, s, strlen(s)) and
 * con_out_block(s, n) became emit(ctx, s, n). Both of those did the same
 * two things (feed the block, feed one CR), which is what let one callback
 * replace two helpers. The words, the column widths, the order of the arms
 * and the choice of renderer are all unchanged - a difference here would
 * show up as the host console and the guest console disagreeing about the
 * same machine, which is the failure this move exists to make impossible.
 */
#include "n68_exec.h"

#include "commands68.h"
#include "log.h"
#include "n68_cmdresult.h"
#include "n68_proclist.h"
#include "n68_vprobe.h"
#include "numfmt.h"
#include "proc68.h"
#include "wire68.h"

#include <stddef.h>
#include <string.h>

/* One rendered command result: two lines of kN68CmdTextCap-ish text plus
 * their labels and the CR between them. Was conwin.c's kRenderCap, moved
 * with the code that sizes against it. */
enum { kRenderCap = 512 };

/* One rendered TABLE result (N68CmdRows), derived from the struct's own
 * caps rather than guessed - was conwin.c's kRowsRenderCap. */
enum { kRowsRenderCap =
           kN68CmdRowsMax * (kN68CmdRowLabelCap + kN68CmdRowValueCap + 1) };

/* ---- emit helpers ---------------------------------------------------- */

static void out(N68ExecEmit emit, void *ctx, const char *s)
{
    emit(ctx, s, (long)strlen(s));
}

/* A failed append leaves pos unspecified (numfmt.h), so it is clamped
 * rather than trusted - the alternative is a NUL written past the end of
 * the buffer on exactly the path that was already going wrong. */
static void out_built(N68ExecEmit emit, void *ctx, char *line, long cap,
                      long pos)
{
    if (pos < 0 || pos > cap - 1) {
        pos = cap - 1;
    }
    line[pos] = '\0';
    out(emit, ctx, line);
}

/* ---- the verbs this file renders itself ------------------------------ */

static void show_help(N68ExecEmit emit, void *ctx)
{
    const N68CommandDoc *docs = now68k_commands_docs();
    int i;

    out(emit, ctx, "NOW-68K console. Commands run on THIS machine.");

    /* The SAME list the wire's `help` answers from (commands68.h), not a
     * second copy. A hand-written list here agreed with that one right up
     * until someone added a command, and then this machine had two
     * different answers to "what can you do". */
    for (i = 0; docs[i].name != NULL; ++i) {
        char line[80];
        long pos = 0;

        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos, "  ");
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                    docs[i].usage);
        while (pos < 28) {
            (void)now68k_fmt_append_str(line, (long)sizeof line, &pos, " ");
        }
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                    docs[i].summary);
        out_built(emit, ctx, line, (long)sizeof line, pos);
    }

    /* Console-only, and deliberately not in that list: the wire's help must
     * not advertise verbs the wire cannot serve. `ps` used to be here; it
     * is in the table now, because the host's console is a dumb shell and
     * could not reach a capability the wire served only as a message
     * family. */
    out(emit, ctx, "  xfer                     an incoming file: where, how far");
    out(emit, ctx, "  clear                    clear this pane");
    out(emit, ctx, "Return runs. Up/Down walk history.");
    out(emit, ctx, "Option-Up/Down (or Page Up/Down) scroll this pane.");
}

const char *now68k_exec_split(const char *line, char *name, int name_cap)
{
    int n = 0;

    while (*line == ' ' || *line == '\t') {
        ++line;
    }
    while (*line != '\0' && *line != ' ' && *line != '\t'
           && n < name_cap - 1) {
        name[n++] = *line++;
    }
    name[n] = '\0';
    /* A name longer than name_cap runs off into the target, which would
     * silently turn a typo into a different command with a strange
     * argument. Consume the rest of the token instead, so the name is
     * simply unrecognized and says so. */
    while (*line != '\0' && *line != ' ' && *line != '\t') {
        ++line;
    }
    while (*line == ' ' || *line == '\t') {
        ++line;
    }
    return line;
}

/* `ps`, rendered for a human from the SAME rows the wire sends as
 * process.listing and as the ps command's reply. Not a second process
 * walk: proc_list_rows() is the one implementation. */
static void show_processes(N68ExecEmit emit, void *ctx)
{
    N68ProcRow rows[NOW68K_PROCLIST_MAX_ROWS];
    long count, i;

    count = proc_list_rows(rows, (long)NOW68K_PROCLIST_MAX_ROWS);
    if (count <= 0) {
        out(emit, ctx, "ps: no processes (the Process Manager returned none)");
        return;
    }

    for (i = 0; i < count; ++i) {
        char line[80];
        long pos = 0;
        const char *kind = (rows[i].kind == kN68ProcKindApplication)
                               ? "app" : "bg ";

        /* Fixed columns rather than a table: a 17-row pane at Monaco 9 is
         * about 58 characters wide, and a name is up to 31 of them. */
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                    rows[i].front ? "* " : "  ");
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos, kind);
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos, " ");
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                    rows[i].name[0] != '\0'
                                        ? rows[i].name : "(unnamed)");
        /* The third face of isSelf. A person at this keyboard has the same
         * question a host does - which of these is the application I am
         * talking to - and the answer is not derivable from the name. */
        if (rows[i].is_self) {
            (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                        " (self)");
        }
        out_built(emit, ctx, line, (long)sizeof line, pos);
    }
}

/* The console's face on moving a file, both directions. A push is a MESSAGE
 * FAMILY, not a command, so no command table compares its two faces - which
 * is precisely the shape process.list drifted in, twice. */
static void show_transfer(N68ExecEmit emit, void *ctx)
{
    N68PutStatus st;
    char line[80];
    char where[64];
    long pos;

    now68k_wire_put_status(&st);
    now68k_wire_put_where(where, (long)sizeof where);

    if (st.active) {
        pos = 0;
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                    "receiving ");
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos, st.name);
        out_built(emit, ctx, line, (long)sizeof line, pos);

        pos = 0;
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos, "  ");
        (void)now68k_fmt_append_long(line, (long)sizeof line, &pos,
                                     st.received);
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos, " of ");
        (void)now68k_fmt_append_long(line, (long)sizeof line, &pos, st.bytes);
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                    " bytes, ");
        (void)now68k_fmt_append_long(line, (long)sizeof line, &pos,
                                     st.writes);
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos, " writes");
        out_built(emit, ctx, line, (long)sizeof line, pos);
    }
    /* The "nothing has happened" line lives below, where it can see BOTH
     * directions - it used to say "no file has arrived this session" while
     * a send was in flight, which is true and reads as false. */

    if (st.had_one) {
        pos = 0;
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                    st.last_ok ? "last: " : "last FAILED: ");
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                    st.last_name);
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos, ", ");
        (void)now68k_fmt_append_long(line, (long)sizeof line, &pos,
                                     st.last_bytes);
        (void)now68k_fmt_append_str(line, (long)sizeof line, &pos, " bytes");
        if (!st.last_ok) {
            (void)now68k_fmt_append_str(line, (long)sizeof line, &pos, " (");
            (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                        st.last_code);
            /* The OSErr, when there is one. "The File Manager refused"
             * names no cause; the number does, and on this machine the
             * number is often the whole diagnosis. */
            if (st.last_error != 0) {
                (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                            " ");
                (void)now68k_fmt_append_long(line, (long)sizeof line, &pos,
                                             (long)st.last_error);
            }
            (void)now68k_fmt_append_str(line, (long)sizeof line, &pos, ")");
        }
        out_built(emit, ctx, line, (long)sizeof line, pos);
    }

    {
        N68SendStatus tx;

        now68k_wire_send_status(&tx);
        if (tx.active) {
            pos = 0;
            (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                        tx.offered ? "offering "
                                                   : "sending ");
            (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                        tx.name);
            out_built(emit, ctx, line, (long)sizeof line, pos);

            if (!tx.offered) {
                pos = 0;
                (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                            "  ");
                (void)now68k_fmt_append_long(line, (long)sizeof line, &pos,
                                             tx.sent);
                (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                            " of ");
                (void)now68k_fmt_append_long(line, (long)sizeof line, &pos,
                                             tx.bytes);
                (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                            " bytes sent");
                out_built(emit, ctx, line, (long)sizeof line, pos);
            }
        }
        if (tx.had_one) {
            pos = 0;
            (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                        tx.last_ok ? "last sent: "
                                                   : "last send FAILED: ");
            (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                        tx.last_name);
            (void)now68k_fmt_append_str(line, (long)sizeof line, &pos, ", ");
            (void)now68k_fmt_append_long(line, (long)sizeof line, &pos,
                                         tx.last_bytes);
            (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                        " bytes");
            if (!tx.last_ok) {
                (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                            " (");
                (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                            tx.last_code);
                (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                            ")");
            }
            out_built(emit, ctx, line, (long)sizeof line, pos);
        }
        if (!st.active && !st.had_one && !tx.active && !tx.had_one) {
            out(emit, ctx, "no file has moved either way this session");
        }
    }

    pos = 0;
    (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                "files land in ");
    (void)now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                where[0] != '\0' ? where
                                                 : "(cannot resolve the folder)");
    out_built(emit, ctx, line, (long)sizeof line, pos);
    out(emit, ctx, "  and `put <name>` sends one from there to the host");
}

/* ---- the dispatch ---------------------------------------------------- */

static void pump(N68ExecPump p)
{
    if (p != NULL) {
        p();
    }
}

int now68k_exec_line(const char *line, N68ExecEmit emit, void *ctx,
                     N68ExecPump pumper)
{
    char name[kN68CmdCodeCap];
    const char *target;
    N68CmdResult res;
    long pos;

    if (emit == NULL) {
        return 0;
    }
    /* An empty line has asked for nothing. Not a failure, and not silence
     * that needs explaining - see ExecRequest.line in the contract. */
    if (line == NULL || line[0] == '\0') {
        return 1;
    }

    target = now68k_exec_split(line, name, (int)sizeof name);
    if (name[0] == '\0') {
        return 1;   /* whitespace only, same as empty */
    }

    if (strcmp(name, "help") == 0 || strcmp(name, "?") == 0) {
        show_help(emit, ctx);
        return 1;
    }
    if (strcmp(name, "ps") == 0) {
        show_processes(emit, ctx);
        return 1;
    }
    if (strcmp(name, "vprobe") == 0) {
        /* The WHOLE table, not the two-row summary an N68CmdResult holds.
         * A measurement command that shows a person two of seventeen rows
         * is reachable from one face and summarised on the other, which is
         * not what docs/command-parity.md means by reachable.
         *
         * Same table the wire renders, borrowed rather than re-measured:
         * running it twice would cost ~12s and could not agree with itself
         * anyway, since the screen may have changed between them. */
        const N68VProbeTable *table;
        char why[128];

        out(emit, ctx, "vprobe: measuring, ~12s, hold the screen still...");
        table = now68k_commands_vprobe(why, (long)sizeof why);
        if (table == NULL) {
            char msg[160];
            long p = 0;

            (void)now68k_fmt_append_str(msg, (long)sizeof msg, &p,
                                        "! vprobe: ");
            (void)now68k_fmt_append_str(msg, (long)sizeof msg, &p,
                                        why[0] != '\0' ? why
                                            : "refused, no reason given");
            out(emit, ctx, msg);
            return 1;
        }
        {
            /* STATIC, not a stack frame. The full table is ~1 KB of text on
             * a path wire68.c's dispatch can already re-enter; another
             * kilobyte there is the wrong kind of thrift. Safe because
             * vprobe68_run refuses re-entry, so two renders can never
             * overlap. */
            static char rendered[NOW68K_VPROBE_JSON_MAX];
            long p = n68_vprobe_render_text(table, rendered,
                                            (long)sizeof rendered);

            if (p > 0) {
                emit(ctx, rendered, p);
            } else {
                out(emit, ctx, "! vprobe: the table did not fit this pane");
            }
        }
        return 1;
    }
    if (strcmp(name, "xfer") == 0) {
        show_transfer(emit, ctx);
        return 1;
    }

    /* proc68.h's catalog walk and quit-confirmation wait are both
     * synchronous and take no callback. Pumping immediately before and
     * after bounds the stall to the command itself rather than letting it
     * compound with whatever else was pending. It does NOT make the command
     * itself pump; nothing here can. NULL for a caller that must not be
     * re-entered - see N68ExecPump. */
    pump(pumper);

    /* The table-shaped commands, reached by DELEGATION and not by a fourth
     * strcmp of this file's own. `ls` is a verb in commands68.c's table
     * that this file never names: it asks whether the table seam claims the
     * word, and renders whatever comes back. */
    {
        const N68CmdRows *rows = now68k_commands_run_rows(name, target);

        if (rows != NULL) {
            char rendered[kRowsRenderCap];

            pump(pumper);
            pos = n68_cmdrows_render_text(rows, rendered,
                                          (long)sizeof rendered);
            if (pos > 0) {
                emit(ctx, rendered, pos);
            } else {
                now68k_log("exec: table did not render");
                out(emit, ctx,
                    "! render-failed: the table did not fit this console");
            }
            return 1;
        }
    }

    if (!now68k_commands_run(name, target, &res)) {
        /* The text face of the same 0 wire68.c answers with the contract's
         * ok=false/"unknown-command" reply. Both faces now come from here,
         * so a host reading exec.output sees the words a person at the
         * PowerBook sees - and the RETURN VALUE is what lets wire68.c still
         * set exec.result's code, because "no such verb" and "the verb said
         * no" are different answers to a tool even though they read the
         * same to a human. */
        static const char kPrefix[] = "! unknown-command: ";
        char msg[sizeof kPrefix + kN68CmdCodeCap];
        size_t nameLen = strlen(name);  /* < kN68CmdCodeCap by the split */

        memcpy(msg, kPrefix, sizeof kPrefix - 1);
        memcpy(msg + sizeof kPrefix - 1, name, nameLen + 1);
        out(emit, ctx, msg);
        pump(pumper);
        return 0;
    }
    pump(pumper);

    {
        char rendered[kRenderCap];

        pos = n68_cmdresult_render_text(&res, rendered, (long)sizeof rendered);
        if (pos > 0) {
            emit(ctx, rendered, pos);
        } else {
            /* n68_cmdresult.c does not log - it does not know which command
             * this was. Same division as commands68.c's dispatch. */
            now68k_log("exec: result did not render");
            out(emit, ctx,
                "! render-failed: the result did not fit this console");
        }
    }
    return 1;
}
