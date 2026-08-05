#include "proc_hide_args.h"

#include <stdio.h>
#include <string.h>

/* Copies one whitespace-delimited token, returning where it stopped. The
   same shape as proc_quit_args.c's, and deliberately not shared with it: a
   four-line lexer is cheaper duplicated than it is coupled, and the two
   grammars are free to diverge (this one has no --wait to consume). */
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

int now_proc_hide_parse(const char *arg, ProcHideArgs *out,
                        char *msg, long cap)
{
    const char *p = arg != NULL ? arg : "";
    int saw_action = 0;
    long len;

    memset(out, 0, sizeof *out);
    out->action = kProcHideActionHide;

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
        if (strcmp(flag, "--show") != 0 && strcmp(flag, "--status") != 0) {
            snprintf(msg, (size_t)cap,
                     "hide: no flag \"%.12s\" - see \"help hide\"", flag);
            return 0;
        }
        /* A second action flag is a line that asks for two things, and
           taking the last one would be a mutation the person did not ask
           for. Refuse rather than pick. */
        if (saw_action) {
            snprintf(msg, (size_t)cap,
                     "hide: one action per line - --show or --status, "
                     "or neither to hide");
            return 0;
        }
        saw_action = 1;
        out->action = strcmp(flag, "--show") == 0 ? kProcHideActionShow
                                                  : kProcHideActionStatus;
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
       inside them - the same courtesy launch and quit extend. */
    if (len >= 2 && p[0] == '"' && p[len - 1] == '"') {
        ++p;
        len -= 2;
    }
    if (len == 0) {
        snprintf(msg, (size_t)cap,
                 "hide what? (the name of a running application, as \"ps\" "
                 "shows it)");
        return 0;
    }
    if (len >= kProcQuitNameMax) {
        snprintf(msg, (size_t)cap,
                 "hide: no process name is longer than %d characters",
                 kProcQuitNameMax - 1);
        return 0;
    }
    memcpy(out->name, p, (size_t)len);
    out->name[len] = '\0';
    return 1;
}

const char *now_proc_hide_state(NowProcHideOutcome outcome)
{
    switch (outcome) {
    case kProcHideHidden:      return "hidden";
    case kProcHideShown:       return "shown";
    case kProcHideReadHidden:  return "is-hidden";
    case kProcHideReadVisible: return "is-visible";
    case kProcHideUnconfirmed: return "unconfirmed";
    case kProcHideNotRunning:  return "not-running";
    case kProcHideAmbiguous:   return "ambiguous";
    case kProcHideRefused:     return "refused";
    case kProcHideUnavailable: return "unavailable";
    case kProcHideBadArgs:     break;
    }
    return "bad-args";
}

const char *now_proc_hide_error(NowProcHideOutcome outcome)
{
    switch (outcome) {
    /* The four the machine was watched arriving at. Nothing else is ok:
       "not running" is NOT the asked-for state here the way it is for
       `quit` - you cannot hide what is not there, and a caller whose next
       step assumes a hidden application must not read it as done. */
    case kProcHideHidden:
    case kProcHideShown:
    case kProcHideReadHidden:
    case kProcHideReadVisible: return NULL;
    case kProcHideUnconfirmed: return "hide-unconfirmed";
    case kProcHideNotRunning:  return "hide-not-running";
    case kProcHideAmbiguous:   return "hide-ambiguous";
    case kProcHideRefused:     return "hide-refused";
    case kProcHideUnavailable: return "hide-unavailable";
    case kProcHideBadArgs:     break;
    }
    return "hide-bad-args";
}

const char *now_proc_hide_visible_word(NowProcHideOutcome outcome)
{
    switch (outcome) {
    case kProcHideHidden:
    case kProcHideReadHidden:  return "no";
    case kProcHideShown:
    case kProcHideReadVisible: return "yes";
    /* Everything else observed NOTHING. kProcHideUnconfirmed is the one
       worth naming: the call was accepted and the flag did not move, so
       the honest answer to "is it visible" is that we do not know, not the
       state we asked it to leave. */
    case kProcHideUnconfirmed:
    case kProcHideNotRunning:
    case kProcHideAmbiguous:
    case kProcHideRefused:
    case kProcHideUnavailable:
    case kProcHideBadArgs:     break;
    }
    return "unknown";
}
