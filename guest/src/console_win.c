#include "console_win.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "capture.h"
#include "commands.h"
#include "json.h"
#include "prefs.h"
#include "screenshot.h"
#include "fileshare.h"
#include "build_stamp.h"
#include "vprobe.h"

enum {
    kMaxLines = 200,
    kMaxCols = 128,
    kLineHeight = 12,
    kMargin = 6,
    kWinWidth = 520,
    kWinHeight = 360
};

static WindowRef g_window = NULL;
static char g_lines[kMaxLines][kMaxCols];
static short g_count = 0;
static char g_input[kMaxCols];
static short g_input_len = 0;
static short g_font = 0;

/* Command history: newest last. g_hist_pos == g_hist_count means "editing a
   fresh line"; arrow keys walk back into the saved commands. */
enum { kHistMax = 32 };
static char g_hist[kHistMax][kMaxCols];
static short g_hist_count = 0;
static short g_hist_pos = 0;

static void history_add(const char *cmd)
{
    if (cmd[0] == '\0') {
        return;
    }
    if (g_hist_count > 0
        && strcmp(g_hist[g_hist_count - 1], cmd) == 0) {
        g_hist_pos = g_hist_count;     /* don't store repeats */
        return;
    }
    if (g_hist_count == kHistMax) {
        memmove(g_hist[0], g_hist[1], (kHistMax - 1) * (size_t)kMaxCols);
        --g_hist_count;
    }
    strncpy(g_hist[g_hist_count], cmd, kMaxCols - 1);
    g_hist[g_hist_count][kMaxCols - 1] = '\0';
    ++g_hist_count;
    g_hist_pos = g_hist_count;
}

static void history_recall(short delta)
{
    short pos = (short)(g_hist_pos + delta);

    if (g_hist_count == 0) {
        return;
    }
    if (pos < 0) {
        pos = 0;
    }
    if (pos > g_hist_count) {
        pos = g_hist_count;
    }
    g_hist_pos = pos;
    if (pos == g_hist_count) {
        g_input[0] = '\0';            /* past the newest: empty line */
        g_input_len = 0;
        return;
    }
    strncpy(g_input, g_hist[pos], kMaxCols - 1);
    g_input[kMaxCols - 1] = '\0';
    g_input_len = (short)strlen(g_input);
}

static void append_line(const char *text)
{
    if (g_count == kMaxLines) {
        memmove(g_lines[0], g_lines[1],
                (kMaxLines - 1) * (size_t)kMaxCols);
        --g_count;
    }
    strncpy(g_lines[g_count], text, kMaxCols - 1);
    g_lines[g_count][kMaxCols - 1] = '\0';
    ++g_count;
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
    char line[kMaxCols];

    if (strcmp(name, "screenshot") == 0) {
        append_line("screenshot - capture the screen to the desktop");
        append_line("  Usage: screenshot [--depth {1,2,4,8,16,32}]");
        append_line("         [--bands N] [--no-save]");
        append_line("  Captures the whole screen as a packed PICT. Depth");
        append_line("  defaults to the Screenshots panel setting; --no-save");
        append_line("  measures capture+encode without writing a file.");
        append_line("  --bands N (2..32) captures in N banded CopyBits");
        append_line("  calls and reports the per-band cost spread.");
    } else if (strcmp(name, "vprobe") == 0) {
        append_line("vprobe - measure VRAM read cost by method");
        append_line("  Usage: vprobe");
        append_line("  Times raw framebuffer reads (8/16/32/64-bit) against");
        append_line("  the CopyBits baseline, checks reread caching, partial-");
        append_line("  read scaling, and pixel fidelity. Takes ~3 seconds;");
        append_line("  the screen should be still during the run.");
    } else if (strcmp(name, "ls") == 0) {
        append_line("ls - list a folder in the shared files");
        append_line("  Usage: ls [path]");
        append_line("  Paths are relative to the share root, with");
        append_line("  colons between folders: \"Lab:Code\". No path");
        append_line("  lists the root itself. The root is chosen in");
        append_line("  File > File Sharing... and defaults to the");
        append_line("  startup volume; nothing outside it is reachable.");
    } else if (strcmp(name, "gestalt") == 0) {
        append_line("gestalt - report this Mac's identity");
        append_line("  Usage: gestalt [group] [--save]");
        append_line("  With no group, prints a short snapshot. Groups:");
        append_line("    --cpu --memory --os --network --hardware");
        append_line("    --full        every group");
        append_line("    --save        also write the output to the desktop");
    } else if (strcmp(name, "help") == 0) {
        append_line("help - list commands; \"help <cmd>\" for one command");
    } else if (strcmp(name, "clear") == 0) {
        append_line("clear - clear the console scrollback");
    } else {
        snprintf(line, sizeof line, "No help for \"%s\"", name);
        append_line(line);
    }
}

static void help_list(void)
{
    append_line("Commands on this Mac:");
    append_line("  gestalt     report this Mac (add a group or --full)");
    append_line("  screenshot  capture the screen (--depth N, --bands N,");
    append_line("              --no-save)");
    append_line("  ls          list a shared folder (ls [path])");
    append_line("  vprobe      measure VRAM read cost by method");
    append_line("  help        show this list (\"help <cmd>\" for details)");
    append_line("  clear       clear the console scrollback");
    append_line("Add --help or -h to any command for details.");
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
            append_line(line);
            gestalt_group_lines(rows, count, kGestaltFullGroups[g],
                                append_line);
        }
    } else if (group != NULL) {
        gestalt_group_lines(rows, count, group, append_line);
    } else {
        gestalt_group_lines(rows, count, "snapshot", append_line);
    }
    if (save) {
        err = gestalt_save(rows, count, full, group);
        if (err == noErr) {
            append_line("Saved to the desktop: \"NOW gestalt.txt\"");
        } else {
            snprintf(line, sizeof line, "Save failed (error %d)", err);
            append_line(line);
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
        append_line(line);
        return;
    }
    snprintf(line, sizeof line,
             "  %dx%d %d-bit  raw %ld KB  PICT %ld KB",
             stats.width, stats.height, stats.depth,
             stats.raw_bytes / 1024, stats.pict_bytes / 1024);
    append_line(line);
    snprintf(line, sizeof line, "  capture %ld ms  encode %ld ms",
             stats.capture_ms, stats.encode_ms);
    append_line(line);
    if (stats.bands > 1) {
        snprintf(line, sizeof line,
                 "  %d bands: min %ld.%ld ms  max %ld.%ld ms",
                 stats.bands,
                 stats.band_min_us / 1000, (stats.band_min_us % 1000) / 100,
                 stats.band_max_us / 1000, (stats.band_max_us % 1000) / 100);
        append_line(line);
    }
    if (no_save) {
        append_line("  (not saved)");
    } else {
        snprintf(line, sizeof line, "  Saved: %.28s", stats.saved_name);
        append_line(line);
    }
}

static void run_command(const char *input)
{
    char line[kMaxCols];
    char name[48];
    char tok[48];
    char target[48];
    char result[512];
    char message[96];
    const char *p;
    const char *group = NULL;
    Boolean want_help = false;
    Boolean full = false;
    Boolean save = false;
    Boolean no_save = false;
    short depth_flag = 0;
    short bands_flag = 0;
    Boolean expect_depth = false;
    Boolean expect_bands = false;

    snprintf(line, sizeof line, "> %s", input);
    append_line(line);

    p = next_token(input, name, sizeof name);
    if (name[0] == '\0') {
        return;
    }
    target[0] = '\0';
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
            append_line(line);
            return;
        }
        for (vi = 0; vi < vn; ++vi) {
            snprintf(line, sizeof line, "  %-16s %s",
                     rows[vi].label, rows[vi].value);
            append_line(line);
        }
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
            append_line(line);
            return;
        }
        now_files_root_name(root, sizeof root);
        snprintf(line, sizeof line, "  %.80s%.40s", root, target);
        append_line(line);
        for (fi = 0; fi < fn; ++fi) {
            now_files_describe(&entries[fi], value, sizeof value);
            snprintf(line, sizeof line, "  %-32.31s%.60s",
                     entries[fi].name, value);
            append_line(line);
        }
        if (fn == 0) {
            append_line("  (empty)");
        } else if (more) {
            append_line("  ... more entries follow");
        }
        return;
    }
    now_command_run(name, NULL, 0, result, sizeof result);
    if (now_json_find_string(result, "message", message, sizeof message)) {
        snprintf(line, sizeof line, "%s", message);
        append_line(line);
    } else {
        append_line("command failed");
    }
}

/* --- window ------------------------------------------------------------- */

void console_win_open(void)
{
    Rect bounds;
    Str255 title;
    Str255 monaco;

    if (g_window != NULL) {
        SelectWindow(g_window);
        return;
    }
    SetRect(&bounds, 40, 60, 40 + kWinWidth, 60 + kWinHeight);
    CreateNewWindow(kDocumentWindowClass,
                    kWindowStandardDocumentAttributes, &bounds, &g_window);
    if (g_window == NULL) {
        return;
    }
    CopyCStringToPascal("Console", title);
    SetWTitle(g_window, title);
    if (g_font == 0) {
        CopyCStringToPascal("Monaco", monaco);
        GetFNum(monaco, &g_font);
    }
    if (g_count == 0) {
        {
            char banner[96];

            snprintf(banner, sizeof banner,
                     "NOW console - runs commands on this Mac.  [%s]",
                     now_build_stamp());
            append_line(banner);
        }
        append_line("Type \"help\" for the list.");
    }
    g_input_len = 0;
    g_input[0] = '\0';
    ShowWindow(g_window);
    SelectWindow(g_window);
}

void console_win_close(void)
{
    if (g_window != NULL) {
        DisposeWindow(g_window);
        g_window = NULL;
    }
}

Boolean console_win_is(WindowRef window)
{
    return g_window != NULL && window == g_window;
}

WindowRef console_win_ref(void)
{
    return g_window;
}

/* The bottom strip that holds the input line. Redrawing only this on each
   keystroke avoids erasing (and flickering) the whole scrollback. */
static void input_rect(const Rect *bounds, Rect *r)
{
    r->left = bounds->left;
    r->right = bounds->right;
    r->bottom = bounds->bottom;
    r->top = (short)(bounds->bottom - kLineHeight - kMargin);
}

static void draw_input(void)
{
    Rect bounds, ir;
    Str255 text;
    char prompt[kMaxCols + 2];

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &bounds);
    input_rect(&bounds, &ir);
    EraseRect(&ir);
    TextFont(g_font);
    TextSize(9);
    snprintf(prompt, sizeof prompt, "> %.120s_", g_input);
    MoveTo((short)(bounds.left + kMargin), (short)(bounds.bottom - kMargin));
    CopyCStringToPascal(prompt, text);
    DrawString(text);
}

void console_win_draw(void)
{
    Rect bounds;
    short content_h, visible, first, i, y;
    Str255 text;

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &bounds);
    EraseRect(&bounds);
    TextFont(g_font);
    TextSize(9);

    content_h = (short)(bounds.bottom - bounds.top);
    visible = (short)((content_h - 2 * kLineHeight) / kLineHeight);
    if (visible < 1) {
        visible = 1;
    }
    first = g_count > visible ? (short)(g_count - visible) : 0;
    y = (short)(bounds.top + kMargin + kLineHeight);
    for (i = first; i < g_count; ++i) {
        MoveTo(bounds.left + kMargin, y);
        CopyCStringToPascal(g_lines[i], text);
        DrawString(text);
        y += kLineHeight;
    }

    /* Input line pinned to the bottom (via draw_input's shared layout). */
    draw_input();
}

void console_win_invalidate(void)
{
    Rect bounds;

    if (g_window == NULL) {
        return;
    }
    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &bounds);
    InvalWindowRect(g_window, &bounds);
}

void console_win_key(char ch)
{
    Rect bounds;

    if (g_window == NULL) {
        return;
    }
    if (ch == '\r' || ch == '\n') {
        long start = 0, end;

        while (g_input[start] == ' ') {
            ++start;
        }
        end = (long)strlen(g_input);
        while (end > start && g_input[end - 1] == ' ') {
            --end;
        }
        g_input[end] = '\0';
        history_add(g_input + start);
        run_command(g_input + start);
        g_input_len = 0;
        g_input[0] = '\0';
        /* The scrollback changed: this is the one case that needs a full
           redraw, so invalidate and let the update event repaint. */
        SetPortWindowPort(g_window);
        GetWindowPortBounds(g_window, &bounds);
        InvalWindowRect(g_window, &bounds);
        return;
    }
    if (ch == 0x1E) {                  /* up arrow: older */
        history_recall(-1);
    } else if (ch == 0x1F) {           /* down arrow: newer */
        history_recall(1);
    } else if (ch == '\b' || ch == 0x7F) {
        if (g_input_len > 0) {
            g_input[--g_input_len] = '\0';
        } else {
            return;
        }
    } else if (ch >= 0x20 && ch < 0x7F) {
        if (g_input_len >= kMaxCols - 2) {
            return;
        }
        g_input[g_input_len++] = ch;
        g_input[g_input_len] = '\0';
    } else {
        return;
    }
    /* Only the input line changed: repaint just that strip, no flicker. */
    draw_input();
}
