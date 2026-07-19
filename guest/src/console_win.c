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

static void run_command(const char *cmd)
{
    char line[kMaxCols];
    char result[512];
    char message[96];

    snprintf(line, sizeof line, "> %s", cmd);
    append_line(line);

    if (cmd[0] == '\0') {
        return;
    }
    if (strcmp(cmd, "clear") == 0) {
        g_count = 0;
        return;
    }
    if (strcmp(cmd, "help") == 0) {
        append_line("Commands: gestalt, help, clear");
        return;
    }
    now_command_run(cmd, 0, result, sizeof result);
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

void console_win_draw(void)
{
    Rect bounds;
    short content_h, visible, first, i, y;
    Str255 text;
    char prompt[kMaxCols + 2];

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

    /* Input line pinned to the bottom, with a caret. */
    snprintf(prompt, sizeof prompt, "> %.120s_", g_input);
    MoveTo(bounds.left + kMargin, (short)(bounds.bottom - kMargin));
    CopyCStringToPascal(prompt, text);
    DrawString(text);
}

void console_win_key(char ch)
{
    Rect bounds;

    if (g_window == NULL) {
        return;
    }
    if (ch == '\r' || ch == '\n') {
        char cmd[kMaxCols];
        long start = 0, end;

        /* trim surrounding spaces */
        while (g_input[start] == ' ') {
            ++start;
        }
        end = (long)strlen(g_input);
        while (end > start && g_input[end - 1] == ' ') {
            --end;
        }
        memcpy(cmd, g_input + start, (size_t)(end - start));
        cmd[end - start] = '\0';
        run_command(cmd);
        g_input_len = 0;
        g_input[0] = '\0';
    } else if (ch == '\b' || ch == 0x7F) {
        if (g_input_len > 0) {
            g_input[--g_input_len] = '\0';
        }
    } else if (ch >= 0x20 && ch < 0x7F) {
        if (g_input_len < kMaxCols - 2) {
            g_input[g_input_len++] = ch;
            g_input[g_input_len] = '\0';
        }
    } else {
        return;
    }
    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &bounds);
    InvalWindowRect(g_window, &bounds);
}
