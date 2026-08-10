#include "console_model.h"
#include "console_reply.h"
#include "loopstat.h"
#include "wirestat_cmd.h"

#include "anchor_cycle.h"
#include "mirror_layout.h"
#include "mirror_probe.h"
#include "mirror_show.h"
#include "net_layout.h"
#include "net_probe.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <Carbon.h>

#include "build_stamp.h"
#include "capture.h"
#include "census.h"
#include "cmd_help.h"
#include "cmd_line.h"
#include "commands.h"
#include "fileshare.h"
#include "json.h"
#include "nowlog.h"
#include "prefs.h"
#include "screenshot.h"
#include "vprobe.h"
#include "catsearch.h"
#include "software.h"
#include "proc_actions.h"
#include "input_cmds.h"
#include "transitions_cmd.h"
#include "wire.h"
#include "contract.h"
#include "../chat/chat_model.h"

enum {
    kMaxLines = kConsoleMaxLines,
    kMaxCols = kConsoleMaxCols
};

static char g_lines[kMaxLines][kMaxCols];
static short g_count = 0;

/* The command history that used to live here is gone, not moved within
   this guest: it is now-guest-shared/src/console_history.c now, one file both
   guests compile, and console_module.c holds the instance the way
   NOW-68K's conwin.c does. This file had its own weaker copy - no saved
   half-typed line, and "" rather than NULL at both ends of a walk, so an
   Up past the oldest entry silently blanked the field. Two consoles
   answering "which line should the field show now" differently was drift
   below the faces docs/command-parity.md is usually about. */

/* Where output goes. NULL is the scrollback, which is what the Workshop's
   Console page reads; anything else is an exec in flight, and the lines go
   there instead.

   A REDIRECT rather than a second dispatch, and that is the whole design:
   every console_model_append call in this file - forty-odd of them,
   including every one added after today - reaches whichever face is asking
   without any of them knowing there are two. A second renderer would have
   drifted the first time somebody added a verb and updated only one, which
   is the failure docs/command-parity.md exists to prevent. */
static ConsoleEmit g_sink = NULL;
static void       *g_sink_ctx = NULL;

/* Set when the dispatch fell all the way through to now_command_run and
   that answered unknown-command. Read once, by console_model_exec, to fill
   exec.result's code; the human has already read the same fact as text. */
static int g_last_unknown = 0;

void console_model_append(const char *text)
{
    if (g_sink != NULL) {
        g_sink(g_sink_ctx, text);
        return;
    }
    if (g_count == kMaxLines) {
        memmove(g_lines[0], g_lines[1],
                (kMaxLines - 1) * (size_t)kMaxCols);
        --g_count;
    }
    strncpy(g_lines[g_count], text, kMaxCols - 1);
    g_lines[g_count][kMaxCols - 1] = '\0';
    ++g_count;
}

/* console_reply.c is Toolbox-free and knows nothing about this file's
   scrollback, so it emits through the same callback shape the exec plane
   uses. This hands it straight back to console_model_append, which is
   where the redirect above then decides which face is listening. */
static void append_thunk(void *ctx, const char *text)
{
    (void)ctx;
    console_model_append(text);
}

/* --- command line: name + unix-style flags ------------------------------ */

static const char *next_token(const char *p, char *out, long cap)
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

static void help_for(const char *name)
{
    const NowCommandDoc *doc = now_command_doc(name);
    char line[kMaxCols];
    int i;

    if (doc == NULL) {
        snprintf(line, sizeof line, "No help for \"%s\"", name);
        console_model_append(line);
        return;
    }
    snprintf(line, sizeof line, "%s - %s", doc->name, doc->summary);
    console_model_append(line);
    snprintf(line, sizeof line, "  Usage: %s", doc->usage);
    console_model_append(line);
    for (i = 0; doc->detail != NULL && doc->detail[i] != NULL; ++i) {
        console_model_append(doc->detail[i]);
    }
}

/* Both halves of help read cmd_help.c's table, which is also what the wire's
   `help` command answers — the other Mac's console keeps no command list of
   its own and asks instead, so a command documented in one place is
   documented in all three. */
static void help_list(void)
{
    char line[kMaxCols];
    int i;

    console_model_append("Commands on this Mac:");
    for (i = 0; kNowCommandDocs[i].name != NULL; ++i) {
        snprintf(line, sizeof line, "  %-11s %s",
                 kNowCommandDocs[i].name, kNowCommandDocs[i].summary);
        console_model_append(line);
    }
    console_model_append("Add --help or -h to any command for details.");
}

/* --- gestalt rendering + save ------------------------------------------- */

/* Collects the lines a gestalt view produces, so they can be both shown and
   (optionally) saved. Maps a --flag to a group name, or NULL for snapshot. */
static const char *flag_to_group(const char *flag)
{
    if (strcmp(flag, "--cpu") == 0) { return "cpu"; }
    if (strcmp(flag, "--memory") == 0) { return "memory"; }
    if (strcmp(flag, "--os") == 0) { return "os"; }
    if (strcmp(flag, "--network") == 0) { return "network"; }
    if (strcmp(flag, "--hardware") == 0) { return "hw"; }
    return NULL;
}

/* Formats one group's rows into out via a callback-free append; returns the
   number of lines written through `emit`. */
static void gestalt_group_lines(const GestaltRow *rows, int count,
                                const char *group,
                                void (*emit)(const char *))
{
    int i;
    char line[kMaxCols];

    for (i = 0; i < count; ++i) {
        if (strcmp(rows[i].group, group) != 0) {
            continue;
        }
        snprintf(line, sizeof line, "  %-14.14s %.60s",
                 rows[i].label, rows[i].value);
        emit(line);
    }
}

/* Writes text lines to "NOW gestalt.txt" on the desktop. Returns 0 on ok. */
static OSErr gestalt_save(const GestaltRow *rows, int count, Boolean full,
                          const char *single_group)
{
    FSSpec spec;
    short vref, ref;
    long dirid;
    OSErr err;
    int i, g;
    char line[kMaxCols + 2];
    long len;

    err = FindFolder(kOnSystemDisk, kDesktopFolderType, kCreateFolder,
                     &vref, &dirid);
    if (err != noErr) {
        return err;
    }
    err = FSMakeFSSpec(vref, dirid,
                       (ConstStr255Param)"\pNOW gestalt.txt", &spec);
    if (err != noErr && err != fnfErr) {
        return err;
    }
    FSpCreate(&spec, 'ttxt', 'TEXT', smSystemScript);
    err = FSpOpenDF(&spec, fsRdWrPerm, &ref);
    if (err != noErr) {
        return err;
    }
    SetEOF(ref, 0);
    for (i = 0; i < count; ++i) {
        Boolean want;
        if (single_group != NULL) {
            want = (strcmp(rows[i].group, single_group) == 0);
        } else if (full) {
            want = (strcmp(rows[i].group, "snapshot") != 0);
        } else {
            want = (strcmp(rows[i].group, "snapshot") == 0);
        }
        if (!want) {
            continue;
        }
        snprintf(line, sizeof line, "%-16s%s\r", rows[i].label, rows[i].value);
        len = (long)strlen(line);
        FSWrite(ref, &len, line);
    }
    (void)g;
    FSClose(ref);
    return noErr;
}

static void run_gestalt_view(const char *group, Boolean full, Boolean save)
{
    GestaltRow rows[kGestaltMaxRows];
    int count = now_gestalt_gather(rows, kGestaltMaxRows);
    char line[kMaxCols];
    OSErr err;
    int g;

    if (full) {
        for (g = 0; kGestaltFullGroups[g] != NULL; ++g) {
            snprintf(line, sizeof line, "[%s]", kGestaltFullGroups[g]);
            console_model_append(line);
            gestalt_group_lines(rows, count, kGestaltFullGroups[g],
                                console_model_append);
        }
    } else if (group != NULL) {
        gestalt_group_lines(rows, count, group, console_model_append);
    } else {
        gestalt_group_lines(rows, count, "snapshot", console_model_append);
    }
    if (save) {
        err = gestalt_save(rows, count, full, group);
        if (err == noErr) {
            console_model_append("Saved to the desktop: \"NOW gestalt.txt\"");
        } else {
            snprintf(line, sizeof line, "Save failed (error %d)", err);
            console_model_append(line);
        }
    }
}

static void run_screenshot_local(short depth_flag, short bands_flag,
                                 Boolean no_save)
{
    NowPrefs prefs;
    ShotStats stats;
    char err[96];
    char line[kMaxCols];
    short depth;
    short bands;

    now_prefs_load(&prefs);
    depth = depth_flag > 0 ? depth_flag : prefs.shot_depth;
    bands = bands_flag > 0 ? bands_flag : 1;
    if (now_screenshot(depth, bands, !no_save, &stats,
                       err, sizeof err) != 0) {
        snprintf(line, sizeof line, "screenshot: %.80s", err);
        console_model_append(line);
        return;
    }
    snprintf(line, sizeof line,
             "  %dx%d %d-bit  raw %ld KB  PICT %ld KB",
             stats.width, stats.height, stats.depth,
             stats.raw_bytes / 1024, stats.pict_bytes / 1024);
    console_model_append(line);
    snprintf(line, sizeof line, "  capture %ld ms  encode %ld ms",
             stats.capture_ms, stats.encode_ms);
    console_model_append(line);
    if (stats.bands > 1) {
        snprintf(line, sizeof line,
                 "  %d bands: min %ld.%ld ms  max %ld.%ld ms",
                 stats.bands,
                 stats.band_min_us / 1000, (stats.band_min_us % 1000) / 100,
                 stats.band_max_us / 1000, (stats.band_max_us % 1000) / 100);
        console_model_append(line);
    }
    if (no_save) {
        console_model_append("  (not saved)");
    } else {
        snprintf(line, sizeof line, "  Saved: %.28s", stats.saved_name);
        console_model_append(line);
    }
}

/* --- chat: the other machine's model -------------------------------------

   Console-only ON PURPOSE, and recorded as such in the host's parity
   map: the family's subject is the HOST's model harness, so the host
   reaches chat by serving it — there is nothing for it to type at this
   Mac. What this verb buys is the command-first proof: through the
   exec plane, `chat hi` typed at the HOST console streams the model's
   answer back as this console's own lines, before any page exists.

   The wait loop pumps the wire until the terminal result, the wire's
   own quiet deadline gives up, or the exec that asked is cancelled.
   While it runs, THIS Mac's own screen does not repaint - stated in
   help, and the page (not this verb) is the interactive face. The
   nested pump is audited in docs/nested-loops.md. */

enum { kChatVerbHardCapTicks = 60 * 300 };  /* five minutes, absolute */

/* The chosen model, held as ref + label: the REF is what a send
   carries and is never printed; the label is what every listing and
   confirmation shows. `--model <n>` picks n from the last listing. */
static char g_chat_model_ref[kChatRefMax + 1];
static char g_chat_model_label[32];
static ChatModelRow g_chat_listed[kChatMaxModels];
static int g_chat_listed_count;
static char g_chat_listed_provider[25];
static ChatLineFeed g_chat_verb_feed;
static Boolean g_chat_verb_done;

static void chat_verb_emit_line(void *ctx, const char *text)
{
    char out[kMaxCols];

    (void)ctx;
    snprintf(out, sizeof out, "  %s", text);
    console_model_append(out);
}

static void chat_verb_note(int kind, const char *reply)
{
    char line[kMaxCols];

    switch (kind) {
    case kChatAnswerProviders: {
        ChatProviderRow rows[kChatMaxProviders];
        int n = chat_parse_providers(reply, rows, kChatMaxProviders);
        int i;

        if (n < 0) {
            console_model_append("  chat: unreadable catalog");
        } else if (n == 0) {
            console_model_append(
                "  the other Mac serves chat but has nothing configured");
        }
        for (i = 0; i < n; ++i) {
            if (strcmp(rows[i].state, "serving") == 0) {
                snprintf(line, sizeof line, "  %-12.12s %.40s",
                         rows[i].provider, rows[i].label);
            } else {
                snprintf(line, sizeof line, "  %-12.12s %.20s (%.14s)",
                         rows[i].provider, rows[i].label, rows[i].state);
            }
            console_model_append(line);
            if (rows[i].detail[0] != '\0'
                && strcmp(rows[i].state, "serving") != 0) {
                snprintf(line, sizeof line, "    %.70s", rows[i].detail);
                console_model_append(line);
            }
        }
        if (n > 0) {
            console_model_append(
                "  chat --models <provider> lists its models");
        }
        g_chat_verb_done = true;
        return;
    }
    case kChatAnswerModels: {
        ChatModelRow page[kChatPageRows];
        char from[25];
        int more = 0;
        int n = chat_parse_models(reply, page, kChatPageRows, &more,
                                  from, sizeof from);
        int i;

        if (n < 0 || strcmp(from, g_chat_listed_provider) != 0) {
            g_chat_verb_done = true;
            return;
        }
        for (i = 0; i < n && g_chat_listed_count < kChatMaxModels; ++i) {
            g_chat_listed[g_chat_listed_count] = page[i];
            snprintf(line, sizeof line, "  %2d. %.40s",
                     g_chat_listed_count + 1, page[i].label);
            console_model_append(line);
            ++g_chat_listed_count;
        }
        if (more && g_chat_listed_count < kChatMaxModels) {
            char err[64];

            /* Auto-pagination: the person asked for the listing, not
               for its pages. */
            if (now_wire_chat_model_page(g_chat_listed_provider,
                                         (long)g_chat_listed_count,
                                         err, sizeof err) == 0) {
                return;               /* the wait continues */
            }
        }
        if (g_chat_listed_count == 0) {
            console_model_append("  (nothing to list)");
        } else {
            console_model_append("  chat --model <n> picks one");
        }
        g_chat_verb_done = true;
        return;
    }
    case kChatAnswerDelta: {
        char text[kNowMaxControl];

        if (chat_parse_delta(reply, text, sizeof text, NULL)) {
            chat_feed_text(&g_chat_verb_feed, text);
        }
        return;
    }
    case kChatAnswerStatus: {
        char text[128];

        if (chat_parse_status(reply, text, sizeof text)
            && text[0] != '\0') {
            snprintf(line, sizeof line, "  .. %.90s", text);
            console_model_append(line);
        }
        return;
    }
    case kChatAnswerGap:
        chat_feed_flush(&g_chat_verb_feed);
        snprintf(line, sizeof line, "  [%.80s]", reply);
        console_model_append(line);
        return;
    case kChatAnswerResult: {
        int ok = 0;
        char code[24];
        char message[96];

        chat_feed_flush(&g_chat_verb_feed);
        if (chat_parse_result(reply, &ok, code, sizeof code,
                              message, sizeof message)
            && !ok) {
            if (message[0] != '\0') {
                snprintf(line, sizeof line, "  chat: %.20s - %.70s",
                         code, message);
            } else {
                snprintf(line, sizeof line, "  chat: %.20s", code);
            }
            console_model_append(line);
        }
        g_chat_verb_done = true;
        return;
    }
    case kChatAnswerError:
        chat_feed_flush(&g_chat_verb_feed);
        snprintf(line, sizeof line, "  chat: %.80s", reply);
        console_model_append(line);
        g_chat_verb_done = true;
        return;
    default:
        return;
    }
}

/* Pump until the note above declares the exchange over. The wire's own
   deadlines (15 s for an ask, 60 s of turn silence) are what normally
   end a wait that will not finish; the hard cap is the backstop, and
   an exec.cancel from the host ends it immediately. */
static void chat_verb_wait(void)
{
    unsigned long deadline = TickCount() + kChatVerbHardCapTicks;
    char err[64];

    while (!g_chat_verb_done) {
        now_wire_pump();
        if (now_wire_exec_cancelled()) {
            now_wire_chat_cancel(err, sizeof err);
            chat_feed_flush(&g_chat_verb_feed);
            console_model_append("  chat: stopped");
            return;
        }
        if ((unsigned long)TickCount() > deadline) {
            now_wire_chat_cancel(err, sizeof err);
            chat_feed_flush(&g_chat_verb_feed);
            console_model_append("  chat: gave up after five minutes");
            return;
        }
    }
}

/* --- showmirror ---------------------------------------------------------
   The typed face on the Mirror page's button. One implementation below
   both — `now_wire_host_show`, with mirror_show.h's words — because a
   second copy would be a second thing to be wrong about an act whose
   whole effect is on the other machine.

   Console-only on this guest, and deliberately: the HOST reaches its
   own Mirror through its Window menu and the `mirror_open` agent verb,
   so there is nothing for it to type at us. Recorded as an asymmetry
   beside `chat`, which is console-only for exactly this shape of
   reason. */

static Boolean g_show_done;
static char g_show_reply[128];

static void show_verb_note(Boolean ok, const char *reason)
{
    snprintf(g_show_reply, sizeof g_show_reply, "%s%.100s",
             ok ? "" : "refused: ", reason);
    g_show_done = true;
}

static void run_show_mirror_verb(void)
{
    char line[kMaxCols];
    char err[96];
    ConnHostShowNote previous;
    unsigned long deadline;

    previous = conn_set_host_show_note(show_verb_note);
    g_show_done = false;
    g_show_reply[0] = '\0';
    if (now_wire_host_show(kMirrorHostSurface, err, sizeof err) != 0) {
        snprintf(line, sizeof line, "showmirror: %.80s", err);
        console_model_append(line);
        conn_set_host_show_note(previous);
        return;
    }
    console_model_append(now_mirror_show_waiting_text());
    /* The wire's own deadline is what ends an ask nobody answers; this
       loop only has to outlive it, and pumping is what lets the answer
       arrive at all. */
    deadline = TickCount() + 60UL * 20UL;
    while (!g_show_done && (unsigned long)TickCount() < deadline) {
        now_wire_pump();
    }
    snprintf(line, sizeof line, "showmirror: %.100s",
             g_show_done ? g_show_reply : "gave up waiting");
    console_model_append(line);
    conn_set_host_show_note(previous);
}

static void run_chat_verb(const char *raw_args)
{
    char line[kMaxCols];
    char err[96];
    char tok[64];
    const char *rest;
    ConnChatNote previous;

    while (*raw_args == ' ') {
        ++raw_args;
    }
    /* Flags are recognised at the START of the line only, so a prompt
       may contain "--" words; "chat -- <text>" forces prompt reading. */
    if (strncmp(raw_args, "-- ", 3) == 0) {
        raw_args += 3;
        while (*raw_args == ' ') {
            ++raw_args;
        }
    } else if (strncmp(raw_args, "--models", 8) == 0
               && (raw_args[8] == ' ' || raw_args[8] == '\0')) {
        rest = next_token(raw_args + 8, tok, sizeof tok);
        (void)rest;
        previous = conn_set_chat_note(chat_verb_note);
        g_chat_verb_done = false;
        if (tok[0] == '\0') {
            /* Step one: the providers. */
            if (now_wire_chat_providers(err, sizeof err) != 0) {
                snprintf(line, sizeof line, "chat: %.80s", err);
                console_model_append(line);
            } else {
                chat_verb_wait();
            }
        } else {
            /* Step two, lazy: the named provider's models, every page. */
            g_chat_listed_count = 0;
            strncpy(g_chat_listed_provider, tok,
                    sizeof g_chat_listed_provider - 1);
            g_chat_listed_provider[sizeof g_chat_listed_provider - 1]
                = '\0';
            if (now_wire_chat_model_page(g_chat_listed_provider, 0,
                                         err, sizeof err) != 0) {
                snprintf(line, sizeof line, "chat: %.80s", err);
                console_model_append(line);
            } else {
                chat_verb_wait();
            }
        }
        conn_set_chat_note(previous);
        return;
    } else if (strncmp(raw_args, "--model", 7) == 0
               && (raw_args[7] == ' ' || raw_args[7] == '\0')) {
        long n;

        rest = next_token(raw_args + 7, tok, sizeof tok);
        (void)rest;
        if (tok[0] == '\0') {
            snprintf(line, sizeof line, "chat: model is %.31s",
                     g_chat_model_label[0] != '\0' ? g_chat_model_label
                                                   : "(not chosen)");
            console_model_append(line);
            return;
        }
        /* A NUMBER from the last listing - the ref underneath is the
           host's business, never typed and never shown. */
        n = strtol(tok, NULL, 10);
        if (n < 1 || n > g_chat_listed_count) {
            console_model_append(
                "chat: pick from a listing - chat --models <provider>, "
                "then chat --model <n>");
            return;
        }
        strcpy(g_chat_model_ref, g_chat_listed[n - 1].ref);
        strncpy(g_chat_model_label, g_chat_listed[n - 1].label,
                sizeof g_chat_model_label - 1);
        g_chat_model_label[sizeof g_chat_model_label - 1] = '\0';
        snprintf(line, sizeof line, "chat: model is %.31s",
                 g_chat_model_label);
        console_model_append(line);
        return;
    } else if (strcmp(raw_args, "--new") == 0) {
        previous = conn_set_chat_note(chat_verb_note);
        g_chat_verb_done = false;
        if (now_wire_chat_reset(err, sizeof err) != 0) {
            snprintf(line, sizeof line, "chat: %.80s", err);
            console_model_append(line);
        } else {
            chat_verb_wait();
            console_model_append("  new conversation");
        }
        conn_set_chat_note(previous);
        return;
    } else if (strcmp(raw_args, "--stop") == 0) {
        if (now_wire_chat_cancel(err, sizeof err) != 0) {
            snprintf(line, sizeof line, "chat: %.80s", err);
            console_model_append(line);
        }
        /* The result lands with whoever holds the hook - the page, or
           the next verb's wait. Nothing to wait for here. */
        return;
    }

    if (raw_args[0] == '\0') {
        console_model_append(
            "chat: chat <text> - see \"help chat\" for the flags");
        return;
    }
    if (g_chat_model_ref[0] == '\0') {
        console_model_append(
            "chat: pick a model first - chat --models <provider>, "
            "then chat --model <n>");
        return;
    }
    previous = conn_set_chat_note(chat_verb_note);
    g_chat_verb_done = false;
    chat_feed_reset(&g_chat_verb_feed, chat_verb_emit_line, NULL);
    if (now_wire_chat_send(g_chat_model_ref, raw_args,
                           err, sizeof err) != 0) {
        snprintf(line, sizeof line, "chat: %.80s", err);
        console_model_append(line);
    } else {
        chat_verb_wait();
    }
    conn_set_chat_note(previous);
}

/* The dispatch proper, WITHOUT the echo. Split out so the exec plane can
   run it without a "> line" the host has already drawn for itself; see
   console_model_exec at the foot of this file. */
/* One LoopStat as two console lines: the summary, then the bucket the
   median fell in. Not the whole histogram - a console is 80 columns and
   ten bins would wrap into unreadability; the wire face carries every
   bin for anything that wants to plot it. */
static void console_show_loopstat(const char *what, const LoopStat *s)
{
    char line[kMaxCols];
    int med = loopstat_median_bucket(s);

    if (s->n <= 0) {
        snprintf(line, sizeof line, "  %s  (no samples)", what);
        console_model_append(line);
        return;
    }
    snprintf(line, sizeof line,
             "  %s  n=%ld mean=%lu us min=%lu max=%lu",
             what, s->n, loopstat_mean_us(s), s->min_us, s->max_us);
    console_model_append(line);
    if (med >= 0) {
        unsigned long hi = loopstat_edge_us(med);

        if (hi != 0) {
            snprintf(line, sizeof line, "          median under %lu us", hi);
        } else {
            snprintf(line, sizeof line, "          median in the top bin");
        }
        console_model_append(line);
    }
}

static void run_shared_verb(const char *name, const char *raw_args)
{
    char result[kNowCommandResultCap];
    char request[kMaxCols + 24];

    if (raw_args != NULL && *raw_args != '\0'
        && now_console_line_request(raw_args, request,
                                    (long)sizeof request)) {
        now_command_run(name, request, 0, result, sizeof result);
    } else {
        now_command_run(name, NULL, 0, result, sizeof result);
    }
    {
        char code[32];

        if (now_json_find_string(result, "code", code, sizeof code)
            && strcmp(code, "unknown-command") == 0) {
            g_last_unknown = 1;
        }
    }
    console_reply_render(result, append_thunk, NULL);
}

static void console_model_dispatch(const char *input)
{
    char line[kMaxCols];
    char name[48];
    char tok[48];
    char target[48];
    char target2[48];
    const char *p;
    const char *raw_args;
    const char *group = NULL;
    Boolean want_help = false;
    Boolean full = false;
    Boolean save = false;
    Boolean no_save = false;
    short depth_flag = 0;
    short bands_flag = 0;
    Boolean expect_depth = false;
    Boolean expect_bands = false;

    p = next_token(input, name, sizeof name);
    if (name[0] == '\0') {
        return;
    }
    raw_args = p;      /* launch takes the rest of the line whole: app
                          names have spaces, and the tokenizer does not */
    target[0] = '\0';
    target2[0] = '\0';
    for (;;) {
        p = next_token(p, tok, sizeof tok);
        if (tok[0] == '\0') {
            break;
        }
        if (expect_depth) {
            long d = strtol(tok, NULL, 10);
            if (capture_depth_is_supported((short)d)) {
                depth_flag = (short)d;
            }
            expect_depth = false;
            continue;
        }
        if (expect_bands) {
            long b = strtol(tok, NULL, 10);
            if (b >= 1 && b <= kCaptureMaxBands) {
                bands_flag = (short)b;
            }
            expect_bands = false;
            continue;
        }
        if (strcmp(tok, "-h") == 0 || strcmp(tok, "--help") == 0) {
            want_help = true;
        } else if (strcmp(tok, "--full") == 0) {
            full = true;
        } else if (strcmp(tok, "--save") == 0) {
            save = true;
        } else if (strcmp(tok, "--no-save") == 0) {
            no_save = true;
        } else if (strcmp(tok, "--depth") == 0) {
            expect_depth = true;
        } else if (strcmp(tok, "--bands") == 0) {
            expect_bands = true;
        } else if (flag_to_group(tok) != NULL) {
            group = flag_to_group(tok);
        } else if (target[0] == '\0' && tok[0] != '-') {
            strncpy(target, tok, sizeof target - 1);
            target[sizeof target - 1] = '\0';
        } else if (target2[0] == '\0' && tok[0] != '-') {
            /* mv is the one verb that names two things. */
            strncpy(target2, tok, sizeof target2 - 1);
            target2[sizeof target2 - 1] = '\0';
        }
    }

    if (strcmp(name, "help") == 0 && target[0] != '\0') {
        help_for(target);
        return;
    }
    if (want_help) {
        help_for(name);
        return;
    }
    if (strcmp(name, "clear") == 0) {
        g_count = 0;
        return;
    }
    if (strcmp(name, "help") == 0) {
        help_list();
        return;
    }
    if (strcmp(name, "update") == 0) {
        run_shared_verb(name, raw_args);
        return;
    }
    if (strcmp(name, "gestalt") == 0) {
        run_gestalt_view(group, full, save);
        return;
    }
    if (strcmp(name, "screenshot") == 0) {
        run_screenshot_local(depth_flag, bands_flag, no_save);
        return;
    }
    if (strcmp(name, "vprobe") == 0) {
        VProbeRow rows[20];
        char verr[96];
        int vn = now_vprobe_run(rows, 20, verr, sizeof verr);
        int vi;

        if (vn < 0) {
            snprintf(line, sizeof line, "vprobe: %.80s", verr);
            console_model_append(line);
            return;
        }
        for (vi = 0; vi < vn; ++vi) {
            snprintf(line, sizeof line, "  %-16s %s",
                     rows[vi].label, rows[vi].value);
            console_model_append(line);
        }
        return;
    }
    if (strcmp(name, "sw") == 0) {
        SoftwareRow rows[kSoftwareRowMax];
        Boolean more = false;
        int sn, si;

        if (target[0] == '\0') {
            sn = now_software_overview(rows, kSoftwareRowMax);
        } else {
            sn = now_software_gather(target, rows, kSoftwareRowMax, &more);
        }
        if (sn < 0) {
            snprintf(line, sizeof line,
                     "sw: no domain \"%.20s\" - see \"help sw\"", target);
            console_model_append(line);
            return;
        }
        for (si = 0; si < sn; ++si) {
            snprintf(line, sizeof line, "  %-32.31s%.60s",
                     rows[si].name, rows[si].detail);
            console_model_append(line);
        }
        if (sn == 0) {
            console_model_append("  (nothing there)");
        } else if (more) {
            console_model_append("  ... more items follow");
        }
        return;
    }
    if (strcmp(name, "showmirror") == 0) {
        run_show_mirror_verb();
        return;
    }
    if (strcmp(name, "chat") == 0) {
        /* Takes the rest of the line whole, like launch: prompts have
           spaces, and the tokenizer does not. */
        run_chat_verb(raw_args);
        return;
    }
    if (strcmp(name, "launch") == 0) {
        char msg[240];

        while (*raw_args == ' ') {
            ++raw_args;
        }
        now_software_launch(raw_args, msg, sizeof msg);
        snprintf(line, sizeof line, "%.120s", msg);
        console_model_append(line);
        return;
    }
    if (strcmp(name, "quit") == 0) {
        char msg[240];

        /* Same whole-rest-of-the-line argument as launch, and the same
           reason: process names have spaces. The parse lives once, in
           proc_quit_args.c, so this path and the wire's cannot drift. */
        while (*raw_args == ' ') {
            ++raw_args;
        }
        (void)now_proc_quit_by_name(raw_args, msg, sizeof msg);
        snprintf(line, sizeof line, "%.120s", msg);
        console_model_append(line);
        return;
    }
    if (strcmp(name, "front") == 0) {
        char msg[240];

        /* Whole rest of the line, like launch and quit, and for the same
           reason: process names have spaces. front has no flags, so
           there is nothing else to parse — proc_actions.c owns what
           little grammar there is, once, for this face and the wire's. */
        while (*raw_args == ' ') {
            ++raw_args;
        }
        (void)now_proc_front_by_name(raw_args, msg, sizeof msg);
        snprintf(line, sizeof line, "%.120s", msg);
        console_model_append(line);
        return;
    }
    if (strcmp(name, "hide") == 0) {
        char msg[240];

        /* Whole rest of the line after any leading flags, like quit and
           for the same reason: process names have spaces. The grammar and
           the outcome vocabulary both live once, in proc_hide_args.c, so
           this face and the wire's cannot come to disagree about what
           "hide --show Finder" means or about what happened. */
        while (*raw_args == ' ') {
            ++raw_args;
        }
        (void)now_proc_hide_by_name(raw_args, msg, sizeof msg);
        snprintf(line, sizeof line, "%.120s", msg);
        console_model_append(line);
        return;
    }
    if (strcmp(name, "key") == 0) {
        char msg[240];

        /* Whole rest of the line, like launch and front: the grammar is
           one or two short tokens and it lives once, in
           now_key_parse_line, so this face and the wire's cannot come to
           disagree about what `key n` means. */
        while (*raw_args == ' ') {
            ++raw_args;
        }
        now_input_key_console(raw_args, msg, sizeof msg);
        snprintf(line, sizeof line, "%.120s", msg);
        console_model_append(line);
        return;
    }
    if (strcmp(name, "reveal") == 0) {
        char msg[240];

        while (*raw_args == ' ') {
            ++raw_args;
        }
        now_software_reveal_target(raw_args, msg, sizeof msg);
        snprintf(line, sizeof line, "%.120s", msg);
        console_model_append(line);
        return;
    }
    if (strcmp(name, "vers") == 0) {
        SoftwareRow rows[40];
        char msg[240];
        int vn, vi;

        while (*raw_args == ' ') {
            ++raw_args;
        }
        vn = now_software_vers(raw_args, rows, 40, msg, sizeof msg);
        if (vn < 0) {
            snprintf(line, sizeof line, "vers: %.100s", msg);
            console_model_append(line);
            return;
        }
        for (vi = 0; vi < vn; ++vi) {
            snprintf(line, sizeof line, "  %-16s %.60s",
                     rows[vi].name, rows[vi].detail);
            console_model_append(line);
        }
        return;
    }
    if (strcmp(name, "catsearch") == 0) {
        CatSearchRow rows[16];
        char cerr[96];
        int cn = now_catsearch_run(rows, 16, cerr, sizeof cerr);
        int ci;

        if (cn < 0) {
            snprintf(line, sizeof line, "catsearch: %.80s", cerr);
            console_model_append(line);
            return;
        }
        for (ci = 0; ci < cn; ++ci) {
            snprintf(line, sizeof line, "  %-16s %s",
                     rows[ci].label, rows[ci].value);
            console_model_append(line);
        }
        return;
    }
    if (strcmp(name, "mv") == 0 || strcmp(name, "trash") == 0
        || strcmp(name, "untrash") == 0 || strcmp(name, "mkdir") == 0) {
        char landed[64];
        int rc;

        landed[0] = '\0';
        if (target[0] == '\0'
            || ((strcmp(name, "mv") == 0 || strcmp(name, "untrash") == 0)
                && target2[0] == '\0')) {
            snprintf(line, sizeof line, "%s: see \"help %s\"", name, name);
            console_model_append(line);
            return;
        }
        if (strcmp(name, "mv") == 0) {
            rc = now_files_move(target, target2, false);
        } else if (strcmp(name, "trash") == 0) {
            rc = now_files_trash(target, landed, sizeof landed);
        } else if (strcmp(name, "untrash") == 0) {
            rc = now_files_restore(target, target2);
        } else {
            rc = now_files_mkdir(target);
        }
        if (rc != kFilesOK) {
            snprintf(line, sizeof line, "%s: %s", name,
                     rc == kFilesBadPath
                         ? "bad path (no \"::\", segments <= 31 chars)"
                     : rc == kFilesNotFound ? "no such item in the share"
                     : rc == kFilesExists ? "something is already there"
                     : "the File Manager refused");
            console_model_append(line);
            return;
        }
        if (landed[0] != '\0') {
            snprintf(line, sizeof line,
                     "trash: in the Trash as \"%.40s\"", landed);
        } else {
            snprintf(line, sizeof line, "%s: done", name);
        }
        console_model_append(line);
        return;
    }
    if (strcmp(name, "ls") == 0) {
        enum { kPage = 48 };
        FileEntry entries[kPage];
        char root[160];
        char value[96];
        Boolean more = false;
        short next = 1;
        int fn, fi;

        fn = now_files_list(target, 1, entries, kPage, &more, &next);
        if (fn < 0) {
            snprintf(line, sizeof line, "ls: %s",
                     fn == kFilesBadPath
                         ? "bad path (no \"::\", segments <= 31 chars)"
                     : fn == kFilesNotFound ? "no such folder in the share"
                     : fn == kFilesNotAFolder ? "that is a file, not a folder"
                     : "the File Manager refused");
            console_model_append(line);
            return;
        }
        now_files_root_name(root, sizeof root);
        snprintf(line, sizeof line, "  %.80s%.40s", root, target);
        console_model_append(line);
        for (fi = 0; fi < fn; ++fi) {
            now_files_describe(&entries[fi], value, sizeof value);
            snprintf(line, sizeof line, "  %-32.31s%.60s",
                     entries[fi].name, value);
            console_model_append(line);
        }
        if (fn == 0) {
            console_model_append("  (empty)");
        } else if (more) {
            console_model_append("  ... more entries follow");
        }
        return;
    }
    if (strcmp(name, "tail") == 0) {
        char lines[2600];
        long count = target[0] != '\0' ? strtol(target, NULL, 10) : 20;
        const char *p;
        int got;

        if (count < 1) { count = 1; }
        if (count > 40) { count = 40; }
        got = now_log_tail((int)count, lines, sizeof lines);
        snprintf(line, sizeof line, "  %s", now_log_path());
        console_model_append(line);
        if (got == 0) {
            console_model_append("  (nothing logged yet)");
            return;
        }
        for (p = lines; *p != '\0'; ) {
            const char *nl = strchr(p, '\n');
            long len = nl != NULL ? (long)(nl - p) : (long)strlen(p);

            if (len > (long)sizeof line - 3) {
                len = (long)sizeof line - 3;
            }
            memcpy(line, p, (size_t)len);
            line[len] = '\0';
            console_model_append(line);
            p = nl != NULL ? nl + 1 : p + strlen(p);
        }
        return;
    }
    if (strcmp(name, "ps") == 0) {
        ProcRow rows[kProcMaxRows];
        int pn = now_process_gather(rows, kProcMaxRows);
        int pi;

        for (pi = 0; pi < pn; ++pi) {
            snprintf(line, sizeof line, "  %-28.31s %s",
                     rows[pi].name, rows[pi].detail);
            console_model_append(line);
        }
        if (pn == 0) {
            console_model_append("  (no processes read)");
        }
        return;
    }
    if (strcmp(name, "wirestat") == 0) {
        /* The same producer the wire verb reads (conn_wake_stats) and the
           same grammar (wirestat_cmd.c) - two renderings, never two
           answers, exactly as `net` does it below. It is NOT routed
           through now_command_run because that path's reply buffer is 512
           bytes and two histograms do not fit; a console that silently
           got "command failed" is how `putstat` has been unreachable from
           the keyboard all along (docs/open-issues.md).

           This verb in particular has to work at the machine: it is the
           instrument for diagnosing a wire, and a person diagnosing a
           wire may have nothing but the keyboard in front of them. */
        ConnWakeStats st;
        WireStatRequest req;
        char action[24];
        char value[24];

        now_wirestat_split(raw_args, action, sizeof action, value,
                           sizeof value);
        now_wirestat_parse(action, value, &req);
        if (req.set_wake) {
            conn_set_wake(req.wake_on);
        }
        if (req.set_sleep) {
            conn_set_idle_sleep(req.sleep_ticks);
        }
        if (req.reset || req.set_wake || req.set_sleep) {
            conn_reset_wake_stats();
        }
        conn_wake_stats(&st);
        snprintf(line, sizeof line,
                 "  sleep now %ld tick(s), idle %ld; wake %s; notifier %s",
                 st.sleep_ticks, conn_idle_sleep(),
                 st.wake_enabled ? "on" : "off",
                 st.notifier_live ? "installed" : "absent");
        console_model_append(line);
        snprintf(line, sizeof line,
                 "  %ld data notifications, %ld wakes",
                 st.data_events, st.wake_calls);
        console_model_append(line);
        console_show_loopstat("pass  ", &st.pass);
        console_show_loopstat("notice", &st.wake);
        return;
    }
    if (strcmp(name, "net") == 0) {
        NetFacts facts;
        NetLinkSample link;
        int sec;

        /* The same probe and the same rows the Networking page draws and
           the wire verb sends. Three faces, one producer - a console that
           computed its own would be a third answer to drift against. */
        memset(&link, 0, sizeof link);
        link.rtt_ms = -1;
        link.quiet_secs = -1;
        if (conn_is_connected()) {
            ConnSnapshot snap;

            conn_snapshot(&snap);
            link.connected = true;
            conn_peer_label(link.peer, (long)sizeof link.peer);
            link.port = (unsigned long)snap.port;
            link.up_secs = snap.connected_secs > 0
                ? (unsigned long)snap.connected_secs : 0UL;
            link.quiet_secs = snap.quiet_secs;
            link.rtt_ms = conn_last_rtt_ms();
            link.rcv_window = conn_rcv_window();
            link.rcv_peak = conn_rcv_peak();
        }
        now_net_probe(&link, &facts);

        for (sec = 0; sec < (int)kNetSectionCount; ++sec) {
            short rows = now_net_section_rows((NetSection)sec, &facts);
            short ri;

            console_model_append(now_net_section_title((NetSection)sec));
            if (rows == 0) {
                NetFactState st = kNetFactNotServed;

                switch ((NetSection)sec) {
                case kNetSectionLink:        st = facts.link.state; break;
                case kNetSectionInet:        st = facts.inet.state; break;
                case kNetSectionPorts:       st = facts.ports_state; break;
                case kNetSectionConnections: st = facts.connections; break;
                case kNetSectionCount:       break;
                }
                snprintf(line, sizeof line, "  %s",
                         now_net_state_sentence(st));
                console_model_append(line);
                continue;
            }
            for (ri = 0; ri < rows; ++ri) {
                char label[32];
                char value[64];

                if (!now_net_row((NetSection)sec, &facts, ri,
                                 label, sizeof label, value, sizeof value)) {
                    break;
                }
                /* Bounded to what a console line holds: the row model
                   allows longer values than this face does, and a
                   truncation the compiler can prove is a truncation the
                   reader should choose rather than discover. */
                snprintf(line, sizeof line, "  %-18.18s %.60s", label, value);
                console_model_append(line);
            }
        }
        return;
    }
    if (strcmp(name, "cycle") == 0) {
        /* The acquisition cycle's console face. Same producer as the wire
           verb (now_peek_anchor_cycle), same numbers, same order - a
           console that computed its own account of what a cycle achieved
           would be a second answer to drift against.

           It ANNOUNCES ITSELF before it runs, because this is the one
           control in the guest that deliberately disturbs the machine: a
           person is about to watch applications come forward in turn and
           should have been told why. */
        NowAnchorCycleReport rep;

        console_model_append("Cycling applications so the anchor plane can "
                             "see them.");
        console_model_append("Windows will come forward in turn; the front "
                             "application is restored after.");
        if (!now_peek_anchor_cycle(&rep)) {
            snprintf(line, sizeof line, "Refused: %.70s", rep.note);
            console_model_append(line);
            return;
        }
        snprintf(line, sizeof line,
                 "Considered %d  anchored already %d  woken %d  "
                 "fronted %d  acquired %d",
                 (int)rep.considered, (int)rep.already, (int)rep.woken,
                 (int)rep.fronted, (int)rep.acquired);
        console_model_append(line);
        snprintf(line, sizeof line,
                 "  refused %d  vanished %d  background-only %d (no window "
                 "to bring forward)",
                 (int)rep.refused, (int)rep.vanished,
                 (int)rep.background_only);
        console_model_append(line);
        /* The evidence, before and after, in the order mirror's Anchors
           line prints it: passes first, because it is what separates
           "the filter never ran while armed" from "it ran and captured
           nothing". */
        snprintf(line, sizeof line,
                 "Anchors  passes %lu -> %lu  scans %lu -> %lu  "
                 "count %lu -> %lu",
                 rep.before_event_passes, rep.after_event_passes,
                 rep.before_slot_scans, rep.after_slot_scans,
                 rep.before_count, rep.after_count);
        console_model_append(line);
        snprintf(line, sizeof line, "%s front application %s",
                 rep.complete ? "Complete." : "PARTIAL -",
                 rep.restored ? "restored." : "NOT restored.");
        console_model_append(line);
        if (rep.unreached_count > 0 || rep.unreached_omitted > 0) {
            int ui;

            /* NAMED, not just counted. These read UNKNOWN to whoever
               consumes the scene next - never empty - and a person
               deciding whether to trust what the Mirror shows needs the
               names rather than the number. */
            console_model_append("Could not reach (their state is UNKNOWN, "
                                 "not empty):");
            for (ui = 0; ui < (int)rep.unreached_count; ++ui) {
                snprintf(line, sizeof line, "  %.40s", rep.unreached[ui]);
                console_model_append(line);
            }
            if (rep.unreached_omitted > 0) {
                snprintf(line, sizeof line, "  ...and %d more",
                         (int)rep.unreached_omitted);
                console_model_append(line);
            }
        }
        if (rep.note[0] != '\0') {
            snprintf(line, sizeof line, "  %.70s", rep.note);
            console_model_append(line);
        }
        return;
    }
    if (strcmp(name, "mirror") == 0) {
        MirrorFacts facts;
        char value[64];
        int mi;

        /* The same probe the Mirror page draws and the wire verb sends,
           rendered by the same layout half - three faces, one producer.
           A console that computed its own account of Mirror would be a
           third answer to drift against. */
        memset(&facts, 0, sizeof facts);
        now_mirror_probe(&facts);

        now_mirror_lifecycle_text(&facts, value, sizeof value);
        console_model_append(value);
        console_model_append("Planes (observed NOW Extension state)");
        for (mi = 0; mi < (int)kMirrorPlaneCount; ++mi) {
            now_mirror_plane_value(&facts, (MirrorPlane)mi,
                                   value, sizeof value);
            snprintf(line, sizeof line, "  %-12.12s %.60s",
                     now_mirror_plane_name((MirrorPlane)mi), value);
            console_model_append(line);
        }
        /* P1's own evidence, at the console because the wire has it and
           command parity is not a preference (docs/command-parity.md).
           `passes` first, deliberately: it is what separates "the filter
           never ran while armed" from "it ran and captured nothing", and
           a person looking at an empty anchor table needs that line
           before any of the others. */
        if (facts.anchors.present || facts.anchors.count > 0) {
            int ai;

            snprintf(line, sizeof line,
                     "Anchors  passes %lu  publishes %lu (%lu changed, "
                     "%lu cadence)  scans %lu",
                     facts.anchors.event_passes,
                     facts.anchors.full_publishes,
                     facts.anchors.change_publishes,
                     facts.anchors.cadence_publishes,
                     facts.anchors.slot_scans);
            console_model_append(line);
            snprintf(line, sizeof line,
                     "  slots %lu captured, %d readable%s",
                     facts.anchors.count, facts.anchors.slot_count,
                     facts.anchors.present ? ""
                         : " (resident predates the counters)");
            console_model_append(line);
            for (ai = 0; ai < facts.anchors.slot_count; ++ai) {
                const MirrorAnchorSlotFact *sl = &facts.anchors.slots[ai];
                snprintf(line, sizeof line,
                         "  %2d %-31.31s a5 0x%08lx  %lu ticks ago",
                         sl->slot, sl->name[0] != '\0' ? sl->name : "?",
                         sl->a5, sl->age_ticks);
                console_model_append(line);
            }
            if (facts.anchors.slots_omitted > 0) {
                snprintf(line, sizeof line,
                         "  %d further slot(s) omitted",
                         facts.anchors.slots_omitted);
                console_model_append(line);
            }
        }
        console_model_append("Policy belongs to the host; this view is read-only.");
        return;
    }
    if (strcmp(name, "transitions") == 0) {
        /* P5's reader, from the machine itself. The facts come from the
           same now_transitions_* implementation the wire verb renders as
           JSON — one producer, two renderers, so a person at the
           PowerBook and the host cannot be told different things about
           the same plane (docs/command-parity.md). */
        char op[16];
        const char *rest = now_transitions_parse_line(raw_args, op,
                                                      (long)sizeof op);

        if (strcmp(op, "status") == 0) {
            NowTransitionsStatus st;

            now_transitions_status(0, &st);
            if (!st.usable) {
                console_model_append(
                    "transitions: no readable plane - the NOW Extension is "
                    "absent, older than P5, or publishing a format this "
                    "build does not read");
                return;
            }
            snprintf(line, sizeof line,
                     "  request        a5 0x%08lx  expiry %lu  %s",
                     (unsigned long)st.arm_a5, (unsigned long)st.arm_expiry,
                     st.arm_commit == 0 ? "not armed"
                                        : (st.expired ? "EXPIRED" : "live"));
            console_model_append(line);
            /* `passes` before the record counts on purpose: it is what
               separates "the resident never ran in that world" from "it
               ran and had nothing to report", and a reader looking at an
               empty ring needs that first. */
            snprintf(line, sizeof line,
                     "  resident       passes %lu  written %lu  dropped %lu",
                     (unsigned long)st.passes,
                     (unsigned long)st.write_cursor,
                     (unsigned long)st.dropped);
            console_model_append(line);
            snprintf(line, sizeof line,
                     "  ring           %lu of %lu pending  %lu lost",
                     st.pending, st.capacity, st.lost);
            console_model_append(line);
            console_model_append(
                "  A sampler, not a tail: what happens and un-happens");
            console_model_append(
                "  between two event passes is still missed.");
            return;
        }
        if (strcmp(op, "start") == 0) {
            NowTransitionsStartReq req;
            NowTransitionsArm arm;
            const char *code = "";
            const char *message = "";

            memset(&req, 0, sizeof req);
            if (rest[0] != '\0') {
                /* The console's route is a NAME and always was: this face
                   builds the Req directly and never met the wire's arg
                   key, which is why the collision that broke the wire
                   left the console line working. */
                req.target = rest;
            } else {
                /* No name is the front process, which typed HERE is NOW
                   itself. The reply names what it armed rather than
                   leaving that to be discovered from an empty drain. */
                req.has_front = 1;
                req.front_true = 1;
            }
            if (!now_transitions_start(&req, &arm, &code, &message)) {
                snprintf(line, sizeof line, "transitions: %.20s - %.90s",
                         code, message);
                console_model_append(line);
                return;
            }
            snprintf(line, sizeof line,
                     "  armed %.31s (a5 0x%08lx, via %s) until tick %lu",
                     arm.process[0] != '\0' ? arm.process : "?",
                     (unsigned long)arm.a5, arm.route,
                     (unsigned long)arm.expiry);
            console_model_append(line);
            console_model_append(
                "  Requested, not armed: nothing records until the resident");
            console_model_append(
                "  agrees inside that process. \"transitions\" shows passes.");
            return;
        }
        if (strcmp(op, "stop") == 0) {
            now_transitions_stop();
            console_model_append(
                "  withdrawn - the resident stops at its next pass in the "
                "target");
            return;
        }
        if (strcmp(op, "drain") == 0) {
            /* Bounded to what a console page usefully shows in one go.
               Draining is the one console subcommand that MOVES the
               shared reader cursor, exactly as the wire's does, so a
               person reading here and a host polling see one ring. */
            enum { kShow = 16 };
            NowEventRecord records[kShow];
            NowTransitionsStatus st;
            NowEventU32 next = 0;
            unsigned long lost = 0;
            unsigned long got;
            unsigned long ri;

            /* Resumes from the SHARED cursor rather than from zero, so a
               person draining here and a host polling the same ring do
               not each replay the other's records. The console has no
               cursor of its own to carry between commands, and inventing
               one would be a second reader the resident's drop accounting
               knows nothing about. */
            now_transitions_status(0, &st);
            if (!st.usable) {
                console_model_append(
                    "transitions: no readable plane - see \"transitions\"");
                return;
            }
            got = now_transitions_read(st.reader_cursor, records, kShow,
                                       &next, &lost, NULL);
            if (lost > 0) {
                snprintf(line, sizeof line,
                         "  %lu records were lost before these", lost);
                console_model_append(line);
            }
            for (ri = 0; ri < got; ++ri) {
                snprintf(line, sizeof line,
                         "  %-8lu %-12.12s 0x%08lx -> 0x%08lx  tick %lu",
                         (unsigned long)records[ri].seq,
                         now_transitions_kind_name(records[ri].kind),
                         (unsigned long)records[ri].previous,
                         (unsigned long)records[ri].value,
                         (unsigned long)records[ri].ticks);
                console_model_append(line);
            }
            if (got == 0) {
                console_model_append("  (no records)");
            }
            now_transitions_commit_read(next);
            return;
        }
        console_model_append(
            "transitions: op must be status, start, stop or drain");
        return;
    }
    if (strcmp(name, "census") == 0) {
        CensusPage page;
        const char *probe = target[0] != '\0' ? target : "overview";
        int ci;

        if (now_census_gather(probe, 0, &page) != 0) {
            snprintf(line, sizeof line,
                     "census: no probe \"%.20s\" - see \"help census\"", probe);
            console_model_append(line);
            return;
        }
        for (ci = 0; ci < page.count; ++ci) {
            const char *value = page.rows[ci].meaning[0] != '\0'
                ? page.rows[ci].meaning : page.rows[ci].raw;
            snprintf(line, sizeof line, "  %-24.31s %.90s",
                     page.rows[ci].name, value);
            console_model_append(line);
        }
        if (page.count == 0 || page.outcome != kCensusPresent
            || page.note[0] != '\0' || page.more) {
            if (page.note[0] != '\0') {
                snprintf(line, sizeof line, "  (%s) %s",
                         census_outcome_name(page.outcome), page.note);
            } else {
                snprintf(line, sizeof line, "  (%s)%s",
                         census_outcome_name(page.outcome),
                         page.more ? " more follows" : "");
            }
            console_model_append(line);
        }
        return;
    }
    if (strcmp(name, "put") == 0) {
        FSSpec spec;
        Str255 hfs;
        char why[128];

        /* A full HFS path, because sending is not browsing: this need
           not be anywhere near the share. */
        if (strchr(target, ':') == NULL) {
            console_model_append("put: needs a full path (\"Macintosh HD:Notes\")");
            return;
        }
        CopyCStringToPascal(target, hfs);
        if (FSMakeFSSpec(0, 0, hfs, &spec) != noErr) {
            console_model_append("put: no such file");
            return;
        }
        if (now_wire_send_file(&spec, why, sizeof why) < 0) {
            snprintf(line, sizeof line, "put: %.80s", why);
            console_model_append(line);
            return;
        }
        console_model_append("  offered; the File Sharing panel reports the rest");
        return;
    }
    /* THE ARGUMENTS A PERSON TYPED, handed on rather than dropped.
     *
     * This call passed NULL for as long as it has existed, so every verb
     * that reaches it with arguments got none: `script tell application
     * "Finder" to activate` answered "script requires source" and
     * `ctlact <element> <part>` answered "ctlact requires part" - both
     * exactly as printed by their own `help`, and both working over the
     * wire. That is the asymmetry docs/command-parity.md is about, and
     * `CommandParityTests` cannot see it because the verb is present on
     * both faces and merely broken on one.
     *
     * `line` is the field the contract already declares for it
     * (CommandRequest.line, and each verb's `x-line`), and cmd_line.h is
     * already the one place every argument grammar is implemented. So
     * this is not a second parser: it hands the raw rest-of-line to the
     * grammar that was always waiting for it.
     *
     * ONLY WHEN THERE ARE ARGUMENTS. An absent line and an empty one are
     * different requests - that distinction is the whole of gestalt's
     * console behaviour - and a bare verb typed here has always meant
     * the absent one. */
    /* Rows, not one field. run_shared_verb is also the one place this Mac
       recognises unknown-command for the exec plane; keeping this fallback
       and explicit argument-taking verbs on it prevents a third renderer. */
    run_shared_verb(name, raw_args);
}

void console_model_run(const char *input)
{
    char line[kMaxCols];

    snprintf(line, sizeof line, "> %s", input);
    console_model_append(line);
    console_model_dispatch(input);
}

int console_model_exec(const char *line, ConsoleEmit emit, void *ctx)
{
    ConsoleEmit saved = g_sink;
    void *saved_ctx = g_sink_ctx;
    int served;

    if (emit == NULL) {
        return 0;
    }
    /* An empty line has asked for nothing: not a failure, and not silence
       that needs explaining (contract: ExecRequest.line). */
    if (line == NULL || line[0] == '\0') {
        return 1;
    }

    g_last_unknown = 0;
    g_sink = emit;
    g_sink_ctx = ctx;
    console_model_dispatch(line);
    g_sink = saved;
    g_sink_ctx = saved_ctx;

    served = !g_last_unknown;
    return served;
}


void console_model_clear(void)
{
    g_count = 0;
}

int console_model_count(void)
{
    return g_count;
}

const char *console_model_line(int index)
{
    if (index < 0 || index >= g_count) {
        return "";
    }
    return g_lines[index];
}

void console_model_banner(void)
{
    char banner[96];

    if (g_count != 0) {
        return;
    }
    snprintf(banner, sizeof banner,
             "NOW console - runs commands on this Mac.  [%s]",
             now_build_stamp());
    console_model_append(banner);
    console_model_append("Type \"help\" for the list.");
}
