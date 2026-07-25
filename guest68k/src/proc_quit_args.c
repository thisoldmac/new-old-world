/*
 * Copied from the PowerPC guest, guest/src/proc_quit_args.c on branch
 * thread/guest-quit-command (see proc_quit_args.h). The PARSING GRAMMAR
 * below is unchanged from that file, character for character - that is the
 * whole point of copying it rather than re-deriving it.
 *
 * What DID change, and the only thing that changed: every snprintf() call
 * became a bounded now68k_fmt_append_str/_long sequence. The PPC guest's
 * copy links freely against InterfaceLib's libc; this target's AGENTS.md
 * forbids the printf family outright (snprintf alone drags ~42 KB of
 * newlib float-formatting machinery into a 384 KB partition - numfmt.h),
 * so the message-building had to be rewritten even though the messages
 * themselves, and the parsing they report on, did not.
 */
#include "proc_quit_args.h"

#include <stdlib.h>
#include <string.h>

#include "numfmt.h"

/* Copies one whitespace-delimited token, returning where it stopped. */
static const char *token(const char *p, char *out, long cap)
{
    long n = 0;

    while (*p == ' ') {
        ++p;
    }
    while (*p != '\0' && *p != ' ' && n + 1 < cap) {
        out[n++] = *p++;
    }
    out[n] = '\0';
    return p;
}

/* Bounded "printf-free printf": builds one message into msg[0, cap) from a
 * run of literal strings and at most one decimal number, matching the
 * shape every call site below needs. Always NUL-terminates on a cap > 0;
 * a message that would not fit is truncated rather than dropped, since a
 * cut-off reason is still more useful to a human than none. */
static void build_msg(char *msg, long cap, const char *a, const char *b,
                      long has_num, long num, const char *c)
{
    long pos = 0;

    if (msg == NULL || cap <= 0) {
        return;
    }
    (void)(now68k_fmt_append_str(msg, cap, &pos, a)
           && (b == NULL || now68k_fmt_append_str(msg, cap, &pos, b))
           && (!has_num || now68k_fmt_append_long(msg, cap, &pos, num))
           && (c == NULL || now68k_fmt_append_str(msg, cap, &pos, c)));
    if (pos >= cap) {
        pos = cap - 1;
    }
    msg[pos] = '\0';
}

int now_proc_quit_parse(const char *arg, ProcQuitArgs *out,
                        char *msg, long cap)
{
    const char *p = arg != NULL ? arg : "";
    long len;

    memset(out, 0, sizeof *out);
    out->confirm = 1;
    out->wait_secs = kProcQuitWaitDefault;

    /* Leading flags only. The first token that is not a flag begins the
       name, and the name runs to the end of the line from there. */
    for (;;) {
        char flag[16];
        const char *after;

        while (*p == ' ') {
            ++p;
        }
        if (*p != '-') {
            break;
        }
        after = token(p, flag, sizeof flag);
        if (strcmp(flag, "--all") == 0) {
            out->all = 1;
        } else if (strcmp(flag, "--no-wait") == 0) {
            out->confirm = 0;
        } else if (strcmp(flag, "--wait") == 0) {
            char number[16];
            long secs;

            after = token(after, number, sizeof number);
            secs = strtol(number, NULL, 10);
            if (number[0] == '\0' || secs < 1) {
                build_msg(msg, cap,
                          "quit: --wait needs a number of seconds (1-",
                          NULL, 1, (long)kProcQuitWaitMax, ")");
                return 0;
            }
            if (secs > kProcQuitWaitMax) {
                secs = kProcQuitWaitMax;   /* clamp, do not refuse: the
                                              ceiling is ours, not theirs */
            }
            out->wait_secs = (int)secs;
            out->confirm = 1;              /* asking to wait longer un-says
                                              an earlier --no-wait */
        } else {
            /* flag[] is already bounded to 15 characters by token()'s cap;
               truncate further to 12 to match the PPC message's %.12s. */
            char shown[13];

            memcpy(shown, flag, sizeof shown - 1);
            shown[sizeof shown - 1] = '\0';
            build_msg(msg, cap, "quit: no flag \"", shown, 0, 0,
                      "\" - see \"help quit\"");
            return 0;
        }
        p = after;
    }

    while (*p == ' ') {
        ++p;
    }
    len = (long)strlen(p);
    while (len > 0 && p[len - 1] == ' ') {
        --len;                             /* a trailing space is typing,
                                              not part of the name */
    }
    /* Quotes are not needed, but a person who types them means the name
       inside them - the same courtesy launch extends. */
    if (len >= 2 && p[0] == '"' && p[len - 1] == '"') {
        ++p;
        len -= 2;
    }
    if (len == 0) {
        build_msg(msg, cap, "quit what? (the name of a running process)",
                  NULL, 0, 0, NULL);
        return 0;
    }
    if (len >= kProcQuitNameMax) {
        build_msg(msg, cap, "quit: no process name is longer than ", NULL,
                  1, (long)(kProcQuitNameMax - 1), " characters");
        return 0;
    }
    memcpy(out->name, p, (size_t)len);
    out->name[len] = '\0';
    return 1;
}
