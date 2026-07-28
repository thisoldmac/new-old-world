#include "proc_quit_args.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
                snprintf(msg, (size_t)cap,
                         "quit: --wait needs a number of seconds (1-%d)",
                         kProcQuitWaitMax);
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
            snprintf(msg, (size_t)cap,
                     "quit: no flag \"%.12s\" - see \"help quit\"", flag);
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
        snprintf(msg, (size_t)cap,
                 "quit what? (the name of a running process)");
        return 0;
    }
    if (len >= kProcQuitNameMax) {
        snprintf(msg, (size_t)cap,
                 "quit: no process name is longer than %d characters",
                 kProcQuitNameMax - 1);
        return 0;
    }
    memcpy(out->name, p, (size_t)len);
    out->name[len] = '\0';
    return 1;
}
