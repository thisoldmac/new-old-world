#include "chat_module.h"

#include <stdio.h>
#include <string.h>

#include "chat_layout.h"
#include "chat_model.h"
#include "../core/contract.h"
#include "../core/pump.h"
#include "../core/wire.h"

/* The Chat page: a transcript of pre-wrapped lines (the Console's
   shape - no variable-height rows anywhere in this application), a
   model popup rebuilt from the host's catalog, and a hand-drawn prompt
   well. The model runs on the OTHER Mac; this page sends one turn and
   draws what streams back. All parsing lives in chat_model.c where the
   host cc can test it; this file is controls, rects and pixels.

   Wire replies arrive through chat_note() from inside the pump, which
   may itself be running under a tracking loop - so the note only
   mutates state and invalidates. Drawing happens in chat_draw() on the
   update event, from state alone. */

enum {
    kChatModelsMenuID = 136
};

static WindowRef g_owner;
static ChatLayoutRects g_r;
static ControlRef g_popup;
static ControlRef g_new_btn;
static ControlRef g_send_btn;
static ControlRef g_scroll;
static ControlActionUPP g_scroll_action_upp;
static short g_font;

static ChatTranscript g_transcript;
static ChatModelRow g_models[kChatMaxModels];
static int g_model_count;
static int g_model_sel = -1;          /* index into g_models, -1 = none */
static Boolean g_asked_catalog;

static char g_input[kChatPromptMax + 1];
static int g_input_len;
static Boolean g_input_focus = true;

static char g_status[128];            /* the transient chat.status line */
static Boolean g_streaming;
static Boolean g_visible;

/* Scroll state, the Console's discipline: pinned to the newest line
   unless the person scrolled away, surviving module switches. */
static int g_top;
static Boolean g_pinned = true;

/* Idle caches: repaint only what changed, because during a transfer
   the loop runs unslept. */
static int g_shown_lines = -1;
static int g_shown_open_len = -1;
static char g_shown_status[128];
static Boolean g_shown_streaming;
static int g_shown_input_len = -1;

/* --- small helpers ------------------------------------------------------ */

static void inval(const Rect *r)
{
    if (g_owner != NULL) {
        InvalWindowRect(g_owner, r);
    }
}

static void draw_at(short x, short y, const char *s)
{
    Str255 p;

    CopyCStringToPascal(s, p);
    MoveTo(x, y);
    DrawString(p);
}

static int visible_lines(void)
{
    return chat_layout_visible_lines(&g_r);
}

static int max_top(void)
{
    int lines = chat_transcript_count(&g_transcript);
    int fit = visible_lines();

    return lines > fit ? lines - fit : 0;
}

static void sync_scrollbar(void)
{
    if (g_scroll == NULL) {
        return;
    }
    SetControlMaximum(g_scroll, (short)max_top());
    SetControlValue(g_scroll, (short)g_top);
}

static void scroll_to(int top, Boolean from_person)
{
    int limit = max_top();

    if (top < 0) {
        top = 0;
    }
    if (top > limit) {
        top = limit;
    }
    if (from_person) {
        g_pinned = top >= limit;
    }
    if (top == g_top) {
        return;
    }
    g_top = top;
    sync_scrollbar();
    inval(&g_r.transcript);
}

/* --- the popup ---------------------------------------------------------- */

static MenuRef popup_menu(void)
{
    MenuRef menu = NULL;
    Size got = 0;

    if (g_popup != NULL
        && GetControlData(g_popup, kControlEntireControl,
                          kControlPopupButtonMenuHandleTag,
                          sizeof menu, (Ptr)&menu, &got) == noErr
        && got == (Size)sizeof menu && menu != NULL) {
        return menu;
    }
    return GetMenuHandle(kChatModelsMenuID);
}

static void rebuild_popup(void)
{
    MenuRef menu = popup_menu();
    int i;

    if (menu == NULL) {
        strcpy(g_status, "The models menu is missing (resource 136)");
        return;
    }
    while (CountMenuItems(menu) > 0) {
        DeleteMenuItem(menu, 1);
    }
    for (i = 0; i < g_model_count; ++i) {
        Str255 label;
        char text[64];

        if (strcmp(g_models[i].state, "serving") == 0) {
            snprintf(text, sizeof text, "%.40s", g_models[i].label);
        } else {
            snprintf(text, sizeof text, "%.30s (%.14s)",
                     g_models[i].label, g_models[i].state);
        }
        /* Appended as a placeholder then renamed: AppendMenu interprets
           metacharacters, and a label is data, not a menu program. */
        CopyCStringToPascal("x", label);
        AppendMenu(menu, label);
        CopyCStringToPascal(text, label);
        SetMenuItemText(menu, (short)(i + 1), label);
        if (strcmp(g_models[i].state, "serving") != 0) {
            DisableMenuItem(menu, (short)(i + 1));
        }
    }
    if (g_model_count == 0) {
        Str255 none;

        CopyCStringToPascal("(ask the other Mac)", none);
        AppendMenu(menu, none);
    }
    if (g_popup != NULL) {
        SetControlMaximum(g_popup, CountMenuItems(menu));
        SetControlValue(g_popup,
                        (short)(g_model_sel >= 0 ? g_model_sel + 1 : 1));
        if (g_visible) {
            Draw1Control(g_popup);
        }
    }
}

static void choose_first_serving(void)
{
    int i;

    if (g_model_sel >= 0 && g_model_sel < g_model_count
        && strcmp(g_models[g_model_sel].state, "serving") == 0) {
        return;
    }
    g_model_sel = -1;
    for (i = 0; i < g_model_count; ++i) {
        if (strcmp(g_models[i].state, "serving") == 0) {
            g_model_sel = i;
            break;
        }
    }
}

/* --- wire notes --------------------------------------------------------- */

static void retitle_send(void)
{
    Str255 title;

    if (g_send_btn == NULL) {
        return;
    }
    CopyCStringToPascal(g_streaming ? "Stop" : "Send", title);
    SetControlTitle(g_send_btn, title);
}

static void chat_note(int kind, const char *reply)
{
    switch (kind) {
    case kChatAnswerCatalog:
        g_model_count = chat_parse_catalog(reply, g_models, kChatMaxModels);
        if (g_model_count < 0) {
            g_model_count = 0;
        }
        choose_first_serving();
        rebuild_popup();
        g_status[0] = '\0';
        break;
    case kChatAnswerDelta: {
        char text[kNowMaxControl];

        if (chat_parse_delta(reply, text, sizeof text, NULL)) {
            chat_transcript_feed(&g_transcript, text);
            if (g_status[0] != '\0') {
                g_status[0] = '\0';
                inval(&g_r.status);
            }
        }
        break;
    }
    case kChatAnswerStatus:
        if (chat_parse_status(reply, g_status, sizeof g_status)) {
            inval(&g_r.status);
        }
        break;
    case kChatAnswerGap:
        chat_transcript_end_answer(&g_transcript);
        chat_transcript_add(&g_transcript, "* ", reply);
        chat_transcript_begin_answer(&g_transcript);
        break;
    case kChatAnswerResult: {
        int ok = 0;
        char code[24];
        char message[96];

        chat_transcript_end_answer(&g_transcript);
        if (chat_parse_result(reply, &ok, code, sizeof code,
                              message, sizeof message)
            && !ok) {
            char line[128];

            if (message[0] != '\0') {
                snprintf(line, sizeof line, "%.20s - %.90s", code, message);
            } else {
                snprintf(line, sizeof line, "%.20s", code);
            }
            chat_transcript_add(&g_transcript, "* ", line);
        }
        g_streaming = false;
        g_status[0] = '\0';
        retitle_send();
        inval(&g_r.status);
        break;
    }
    case kChatAnswerError:
        chat_transcript_end_answer(&g_transcript);
        chat_transcript_add(&g_transcript, "* ", reply);
        g_streaming = false;
        g_status[0] = '\0';
        retitle_send();
        inval(&g_r.status);
        break;
    default:
        break;
    }
    /* The idle caches notice the line count moved and repaint only the
       pane; scroll follows the tail while pinned. */
    if (g_pinned) {
        g_top = max_top();
    }
    sync_scrollbar();
}

/* --- actions ------------------------------------------------------------ */

static void ask_catalog(void)
{
    char err[96];

    if (now_wire_chat_models(err, sizeof err) != 0) {
        snprintf(g_status, sizeof g_status, "%.120s", err);
        inval(&g_r.status);
        return;
    }
    g_asked_catalog = true;
}

static void send_or_stop(void)
{
    char err[96];

    if (g_streaming) {
        if (now_wire_chat_cancel(err, sizeof err) != 0) {
            snprintf(g_status, sizeof g_status, "%.120s", err);
            inval(&g_r.status);
        }
        return;
    }
    if (g_input_len == 0) {
        return;
    }
    if (g_model_sel < 0 || g_model_sel >= g_model_count) {
        strcpy(g_status, "Pick a model first");
        inval(&g_r.status);
        return;
    }
    if (now_wire_chat_send(g_models[g_model_sel].model, g_input,
                           err, sizeof err) != 0) {
        snprintf(g_status, sizeof g_status, "%.120s", err);
        inval(&g_r.status);
        return;
    }
    chat_transcript_add(&g_transcript, "> ", g_input);
    chat_transcript_begin_answer(&g_transcript);
    g_input[0] = '\0';
    g_input_len = 0;
    g_streaming = true;
    g_pinned = true;
    g_top = max_top();
    retitle_send();
    sync_scrollbar();
    inval(&g_r.input);
    inval(&g_r.transcript);
}

static void new_chat(void)
{
    char err[96];

    if (g_streaming) {
        strcpy(g_status, "Stop the answer first");
        inval(&g_r.status);
        return;
    }
    if (now_wire_chat_reset(err, sizeof err) != 0) {
        snprintf(g_status, sizeof g_status, "%.120s", err);
        inval(&g_r.status);
        return;
    }
    chat_transcript_reset(&g_transcript);
    g_top = 0;
    g_pinned = true;
    sync_scrollbar();
    inval(&g_r.transcript);
}

/* --- scrolling ---------------------------------------------------------- */

static pascal void scroll_action(ControlRef control, ControlPartCode part)
{
    int page = visible_lines() - 1;

    if (page < 1) {
        page = 1;
    }
    switch (part) {
    case kControlUpButtonPart:
        scroll_to(g_top - 1, true);
        break;
    case kControlDownButtonPart:
        scroll_to(g_top + 1, true);
        break;
    case kControlPageUpPart:
        scroll_to(g_top - page, true);
        break;
    case kControlPageDownPart:
        scroll_to(g_top + page, true);
        break;
    default:
        break;
    }
    (void)control;
}

/* --- the ops ------------------------------------------------------------ */

static OSErr chat_create(WindowRef owner, const Rect *body)
{
    Str255 text;

    g_owner = owner;
    chat_layout_compute(body, &g_r);
    if (g_font == 0) {
        Str255 geneva;

        CopyCStringToPascal("Geneva", geneva);
        GetFNum(geneva, &g_font);
    }
    chat_transcript_reset(&g_transcript);

    text[0] = 0;
    g_popup = NewControl(owner, &g_r.popup, text, false,
                         popupTitleLeftJust, kChatModelsMenuID, 0,
                         popupMenuProc, 0);
    CopyCStringToPascal("New Chat", text);
    g_new_btn = NewControl(owner, &g_r.new_button, text, false, 0, 0, 1,
                           pushButProc, 0);
    CopyCStringToPascal("Send", text);
    g_send_btn = NewControl(owner, &g_r.send_button, text, false, 0, 0, 1,
                            pushButProc, 0);
    g_scroll_action_upp = NewControlActionUPP(scroll_action);
    g_scroll = NewControl(owner, &g_r.scrollbar, text, false, 0, 0, 0,
                          scrollBarProc, 0);
    if (g_popup == NULL || g_new_btn == NULL || g_send_btn == NULL
        || g_scroll == NULL || g_scroll_action_upp == NULL) {
        return memFullErr;
    }
    rebuild_popup();
    conn_set_chat_note(chat_note);
    return noErr;
}

static void chat_dispose(void)
{
    /* The window owns the controls (DisposeWindow takes them); this
       module releases only what it constructed itself. */
    conn_set_chat_note(NULL);
    if (g_scroll_action_upp != NULL) {
        DisposeControlActionUPP(g_scroll_action_upp);
        g_scroll_action_upp = NULL;
    }
    g_popup = NULL;
    g_new_btn = NULL;
    g_send_btn = NULL;
    g_scroll = NULL;
    g_owner = NULL;
}

static void chat_show(Boolean visible)
{
    g_visible = visible;
    if (visible) {
        ShowControl(g_popup);
        ShowControl(g_new_btn);
        ShowControl(g_send_btn);
        ShowControl(g_scroll);
        g_input_focus = true;
        if (!g_asked_catalog && conn_phase() == kConnConnected) {
            ask_catalog();
        }
        /* Force the caches stale so the first draw is whole. */
        g_shown_lines = -1;
        g_shown_input_len = -1;
        g_shown_status[0] = '\0';
    } else {
        HideControl(g_popup);
        HideControl(g_new_btn);
        HideControl(g_send_btn);
        HideControl(g_scroll);
        g_input_focus = false;        /* keys must not land in a hidden page */
    }
}

static void chat_layout_op(const Rect *body)
{
    chat_layout_compute(body, &g_r);
    MoveControl(g_popup, g_r.popup.left, g_r.popup.top);
    SizeControl(g_popup, (short)(g_r.popup.right - g_r.popup.left),
                (short)(g_r.popup.bottom - g_r.popup.top));
    MoveControl(g_new_btn, g_r.new_button.left, g_r.new_button.top);
    SizeControl(g_new_btn,
                (short)(g_r.new_button.right - g_r.new_button.left),
                (short)(g_r.new_button.bottom - g_r.new_button.top));
    MoveControl(g_send_btn, g_r.send_button.left, g_r.send_button.top);
    SizeControl(g_send_btn,
                (short)(g_r.send_button.right - g_r.send_button.left),
                (short)(g_r.send_button.bottom - g_r.send_button.top));
    MoveControl(g_scroll, g_r.scrollbar.left, g_r.scrollbar.top);
    SizeControl(g_scroll,
                (short)(g_r.scrollbar.right - g_r.scrollbar.left),
                (short)(g_r.scrollbar.bottom - g_r.scrollbar.top));
    if (g_pinned) {
        g_top = max_top();
    }
    sync_scrollbar();
}

static void draw_transcript(void)
{
    Rect f = g_r.transcript;
    RgnHandle saved = NewRgn();
    int fit = visible_lines();
    int lines = chat_transcript_count(&g_transcript);
    int i;
    short x = (short)(f.left + 5);
    short y = (short)(f.top + 4 + (kChatLineHeight - 3));

    EraseRect(&f);
    FrameRect(&f);
    if (saved != NULL) {
        GetClip(saved);
        ClipRect(&f);
    }
    TextFont(g_font);
    TextSize(9);
    TextFace(normal);
    for (i = 0; i < fit; ++i) {
        int line = g_top + i;

        if (line >= lines) {
            break;
        }
        draw_at(x, y, chat_transcript_line(&g_transcript, line));
        y = (short)(y + kChatLineHeight);
    }
    if (lines == 0) {
        draw_at(x, (short)(f.top + 16),
                g_model_count > 0
                    ? "Ask the other Mac's model about this one."
                    : "Waiting for the other Mac's models...");
    }
    if (saved != NULL) {
        SetClip(saved);
        DisposeRgn(saved);
    }
}

static void draw_status_line(void)
{
    EraseRect(&g_r.status);
    if (g_status[0] == '\0') {
        return;
    }
    TextFont(g_font);
    TextSize(9);
    TextFace(italic);
    draw_at((short)(g_r.status.left + 2),
            (short)(g_r.status.bottom - 3), g_status);
    TextFace(normal);
}

static void draw_input(void)
{
    Rect f = g_r.input;
    char shown[kChatPromptMax + 2];
    int width = f.right - f.left - 10;
    const char *text = g_input;

    EraseRect(&f);
    FrameRect(&f);
    TextFont(g_font);
    TextSize(9);
    /* Tail-scroll: when the text outgrows the well, show its end -
       that is where the caret and the person's attention are. */
    while (text[0] != '\0' && TextWidth(text, 0, (short)strlen(text))
               > width - 6) {
        ++text;
    }
    if (g_input_len == 0 && !g_streaming) {
        TextFace(italic);
        draw_at((short)(f.left + 5), (short)(f.bottom - 7),
                "Type here, Return sends");
        TextFace(normal);
        return;
    }
    snprintf(shown, sizeof shown, "%s%s", text,
             g_input_focus && !g_streaming ? "|" : "");
    draw_at((short)(f.left + 5), (short)(f.bottom - 7), shown);
}

static void chat_draw(void)
{
    draw_transcript();
    draw_status_line();
    draw_input();
    g_shown_lines = chat_transcript_count(&g_transcript);
    g_shown_open_len = g_transcript.feed.open_len;
    strncpy(g_shown_status, g_status, sizeof g_shown_status - 1);
    g_shown_streaming = g_streaming;
    g_shown_input_len = g_input_len;
}

static Boolean chat_click(const EventRecord *event, Point local)
{
    ControlRef control;
    ControlPartCode part;

    part = FindControl(local, g_owner, &control);
    if (control == g_popup && part != 0) {
        /* Popup CDEFs run their own action; never hand them the pump. */
        if (TrackControl(g_popup, local, (ControlActionUPP)-1L) != 0) {
            int picked = GetControlValue(g_popup) - 1;

            if (picked >= 0 && picked < g_model_count) {
                g_model_sel = picked;
            }
        }
        return true;
    }
    if (control == g_new_btn && part != 0) {
        if (TrackControl(g_new_btn, local, now_pump_action()) != 0) {
            new_chat();
        }
        return true;
    }
    if (control == g_send_btn && part != 0) {
        if (TrackControl(g_send_btn, local, now_pump_action()) != 0) {
            send_or_stop();
        }
        return true;
    }
    if (control == g_scroll && part != 0) {
        if (part == kControlIndicatorPart) {
            /* Thumb tracking takes NULL; the value lands at mouse-up. */
            if (TrackControl(g_scroll, local, NULL) != 0) {
                scroll_to(GetControlValue(g_scroll), true);
            }
        } else {
            TrackControl(g_scroll, local, g_scroll_action_upp);
        }
        return true;
    }
    if (PtInRect(local, &g_r.input)) {
        if (!g_input_focus) {
            g_input_focus = true;
            inval(&g_r.input);
        }
        return true;
    }
    if (PtInRect(local, &g_r.transcript)) {
        return true;                  /* claimed; nothing to do yet */
    }
    (void)event;
    return false;
}

static Boolean chat_key(const EventRecord *event)
{
    char c = (char)(event->message & charCodeMask);

    if (!g_input_focus) {
        return false;
    }
    if (c == '\r' || c == 3) {
        send_or_stop();
        return true;
    }
    if (c == 0x08) {
        if (g_input_len > 0) {
            g_input[--g_input_len] = '\0';
            inval(&g_r.input);
        }
        return true;
    }
    if (c == 0x0B || c == 0x0C) {     /* page up / page down */
        scroll_to(g_top + (c == 0x0C ? visible_lines() - 1
                                     : -(visible_lines() - 1)), true);
        return true;
    }
    if ((unsigned char)c >= 0x20 && (unsigned char)c < 0x7F) {
        if (g_input_len < kChatPromptMax) {
            g_input[g_input_len++] = c;
            g_input[g_input_len] = '\0';
            inval(&g_r.input);
        }
        return true;
    }
    return false;
}

static void chat_activate(Boolean active)
{
    if (g_popup == NULL) {
        return;
    }
    if (active) {
        ActivateControl(g_popup);
        ActivateControl(g_new_btn);
        ActivateControl(g_send_btn);
        ActivateControl(g_scroll);
    } else {
        DeactivateControl(g_popup);
        DeactivateControl(g_new_btn);
        DeactivateControl(g_send_btn);
        DeactivateControl(g_scroll);
    }
}

static void chat_idle(void)
{
    /* Nearly free: compare the caches, invalidate only what moved. */
    if (!g_visible) {
        return;
    }
    if (chat_transcript_count(&g_transcript) != g_shown_lines
        || g_transcript.feed.open_len != g_shown_open_len) {
        if (g_pinned) {
            g_top = max_top();
            sync_scrollbar();
        }
        inval(&g_r.transcript);
        g_shown_lines = chat_transcript_count(&g_transcript);
        g_shown_open_len = g_transcript.feed.open_len;
    }
    if (strcmp(g_status, g_shown_status) != 0) {
        inval(&g_r.status);
        strncpy(g_shown_status, g_status, sizeof g_shown_status - 1);
    }
    if (g_streaming != g_shown_streaming) {
        inval(&g_r.input);
        g_shown_streaming = g_streaming;
    }
    if (g_input_len != g_shown_input_len) {
        inval(&g_r.input);
        g_shown_input_len = g_input_len;
    }
    /* The catalog is asked once per connection; a page shown before
       the wire came up asks as soon as it is there. */
    if (!g_asked_catalog && conn_phase() == kConnConnected) {
        ask_catalog();
    }
    if (g_asked_catalog && conn_phase() != kConnConnected) {
        g_asked_catalog = false;      /* re-ask after a reconnect */
    }
}

static void chat_status_text(char *out, long cap)
{
    if (conn_phase() != kConnConnected) {
        snprintf(out, (size_t)cap, "Chat needs the connection");
        return;
    }
    if (g_streaming) {
        snprintf(out, (size_t)cap, "Answering... Stop ends it");
        return;
    }
    if (g_model_count > 0) {
        int serving = 0;
        int i;

        for (i = 0; i < g_model_count; ++i) {
            if (strcmp(g_models[i].state, "serving") == 0) {
                ++serving;
            }
        }
        snprintf(out, (size_t)cap, "%d model%s from the other Mac",
                 serving, serving == 1 ? "" : "s");
        return;
    }
    snprintf(out, (size_t)cap,
             g_asked_catalog ? "That Mac offers no chat"
                             : "Asking about models...");
}

const WorkshopModuleOps *chat_module_ops(void)
{
    static const WorkshopModuleOps k_ops = {
        chat_create,
        chat_dispose,
        chat_show,
        chat_layout_op,
        chat_draw,
        chat_click,
        chat_key,
        chat_activate,
        chat_idle,
        chat_status_text
    };

    return &k_ops;
}
