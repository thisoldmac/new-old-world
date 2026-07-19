#include "console_win.h"

#include <stdio.h>
#include <string.h>

#include "commands.h"

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

/* --- minimal JSON scan (reads commands.c's own result) ------------------ */

static int json_find_string(const char *json, const char *key,
                            char *out, long cap)
{
    char pattern[48];
    const char *p;
    long n = 0;

    snprintf(pattern, sizeof pattern, "\"%s\":\"", key);
    p = strstr(json, pattern);
    if (p == NULL) {
        return 0;
    }
    p += strlen(pattern);
    while (*p != '\0' && *p != '"' && n + 1 < cap) {
        out[n++] = *p++;
    }
    out[n] = '\0';
    return 1;
}

/* Render every "key":"value" pair inside the result's output object, one
   aligned line each — generic, so new commands need no console changes. */
static void render_output(const char *result)
{
    const char *p = strstr(result, "\"output\":{");
    char line[kMaxCols];
    char key[48];
    char value[80];

    if (p == NULL) {
        append_line("(no output)");
        return;
    }
    p += strlen("\"output\":{");
    for (;;) {
        long n = 0;
        while (*p != '\0' && *p != '"' && *p != '}') {
            ++p;
        }
        if (*p != '"') {
            break;
        }
        ++p;
        while (*p != '\0' && *p != '"' && n + 1 < (long)sizeof key) {
            key[n++] = *p++;
        }
        key[n] = '\0';
        if (*p == '"') {
            ++p;
        }
        while (*p != '\0' && *p != '"' && *p != '}') {
            ++p;                       /* skip ':' and whitespace */
        }
        if (*p != '"') {
            break;
        }
        ++p;
        n = 0;
        while (*p != '\0' && *p != '"' && n + 1 < (long)sizeof value) {
            value[n++] = *p++;
        }
        value[n] = '\0';
        if (*p == '"') {
            ++p;
        }
        snprintf(line, sizeof line, "  %-12.12s %.60s", key, value);
        append_line(line);
    }
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

    if (strcmp(name, "gestalt") == 0) {
        append_line("gestalt - report this Mac's identity");
        append_line("  Usage: gestalt");
        append_line("  Reports the running system version, the Gestalt");
        append_line("  machine type, physical RAM, and the installed");
        append_line("  CarbonLib version.");
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
    append_line("  gestalt   report system, model, RAM, CarbonLib");
    append_line("  help      show this list (\"help <cmd>\" for details)");
    append_line("  clear     clear the console scrollback");
    append_line("Add --help or -h to any command for details.");
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
    Boolean want_help = false;

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
        if (strcmp(tok, "-h") == 0 || strcmp(tok, "--help") == 0) {
            want_help = true;
        } else if (target[0] == '\0') {
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
    now_command_run(name, 0, result, sizeof result);
    if (strstr(result, "\"ok\":true") != NULL) {
        render_output(result);
    } else if (json_find_string(result, "message", message, sizeof message)) {
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
        append_line("NOW console - runs commands on this Mac.");
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
    if (ch == '\b' || ch == 0x7F) {
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
