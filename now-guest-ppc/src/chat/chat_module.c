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
   model popup rebuilt from the host's catalog, and a REAL edit-text
   control for the prompt - the Control Manager owns its pixels, caret
   and selection, so typing repaints nothing of ours. The model runs on
   the OTHER Mac; this page sends one turn and draws what streams back.
   All parsing lives in chat_model.c where the host cc can test it;
   this file is controls, rects and pixels.

   Wire replies arrive through chat_note() from inside the pump, which
   may itself be running under a tracking loop - so the note only
   mutates state and invalidates. Drawing happens in chat_draw() on the
   update event, from state alone - and the damage is per ROW: a chunk
   that only lengthens the open tail line invalidates that one line's
   rect, never the pane (metal, 2026-08-02: whole-pane damage per chunk
   read as flicker at streaming cadence).

   The prompt is CLASSIC TEXTEDIT, not an Appearance edit-text control,
   and the choice is measured, not taste: this window has no root
   control ON PURPOSE (workshop_window.c says why - embedding broke
   click routing in a WaitNextEvent app), so SetKeyboardFocus fails and
   the control CDEF's keys never arrive; the console's first field died
   of exactly this, and an emulator run of the control here (2026-08-02)
   typed into a field that stayed empty. TE needs no focus machinery:
   TEKey inserts and draws incrementally, TEClick places the caret and
   tracks selection, TEIdle blinks, TEActivate follows the window - the
   same text engine every classic dialog field is made of. */

enum {
    kChatModelsMenuID = 136,
    kChatProvidersMenuID = 137
};

static WindowRef g_owner;
static ChatLayoutRects g_r;
static ControlRef g_provider_popup;
static ControlRef g_model_popup;
static ControlRef g_new_btn;
static ControlRef g_send_btn;
static ControlRef g_scroll;
static ControlActionUPP g_scroll_action_upp;
static short g_font;

static ChatTranscript g_transcript;
static ChatModelRow g_models[kChatMaxModels];
static int g_model_count;
/* The two popups' view of the rows: distinct providers, and the rows
   of the chosen one. g_row_sel is the CATALOG index the Send uses. */
static char g_providers[kChatMaxModels][24];
static int g_provider_count;
static int g_provider_sel;
static int g_filtered[kChatMaxModels];
static int g_filtered_count;
static int g_filtered_sel = -1;
static int g_row_sel = -1;            /* index into g_models, -1 = none */
static Boolean g_asked_catalog;

static TEHandle g_te;                 /* the prompt; TE draws it */

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

/* Damage for transcript lines [from, to) in transcript coordinates,
   clipped to the rows the pane shows. The streaming path's whole point:
   one lengthened tail line invalidates one row's rect. */
static void inval_rows(int from, int to)
{
    int fit = visible_lines();
    int first = from - g_top;
    int last = to - g_top;
    Rect r;

    if (first < 0) {
        first = 0;
    }
    if (last > fit) {
        last = fit;
    }
    if (first >= last) {
        return;
    }
    r.left = (short)(g_r.transcript.left + 1);
    r.right = (short)(g_r.transcript.right - 1);
    r.top = (short)(g_r.transcript.top + 4 + first * kChatLineHeight);
    r.bottom = (short)(g_r.transcript.top + 4 + last * kChatLineHeight);
    inval(&r);
}

/* --- the prompt (TextEdit) ----------------------------------------------- */

static void prompt_rects(Rect *view, Rect *dest)
{
    *view = g_r.input;
    InsetRect(view, 4, 3);
    /* Single line: the destination is far wider than the view, so TE
       never wraps, and TEAutoView keeps the caret's end in sight. */
    *dest = *view;
    dest->right = (short)(dest->left + 2000);
}

static long prompt_size(void)
{
    return g_te != NULL ? (*g_te)->teLength : 0;
}

static long prompt_text(char *out, long cap)
{
    long len = prompt_size();
    CharsHandle chars;

    if (len > cap - 1) {
        len = cap - 1;
    }
    chars = g_te != NULL ? TEGetText(g_te) : NULL;
    if (chars == NULL) {
        len = 0;
    } else {
        HLock((Handle)chars);
        memcpy(out, *chars, (size_t)len);
        HUnlock((Handle)chars);
    }
    out[len] = '\0';
    return len;
}

static void prompt_clear(void)
{
    if (g_te == NULL) {
        return;
    }
    TESetText("", 0, g_te);
    inval(&g_r.input);                /* TESetText mutates, never draws */
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

/* --- the two popups ------------------------------------------------------ */

static MenuRef popup_menu(ControlRef popup, short fallback_id)
{
    MenuRef menu = NULL;
    Size got = 0;

    if (popup != NULL
        && GetControlData(popup, kControlEntireControl,
                          kControlPopupButtonMenuHandleTag,
                          sizeof menu, (Ptr)&menu, &got) == noErr
        && got == (Size)sizeof menu && menu != NULL) {
        return menu;
    }
    return GetMenuHandle(fallback_id);
}

static void fill_menu_item(MenuRef menu, short item, const char *text,
                           Boolean enabled)
{
    Str255 label;

    /* Appended as a placeholder then renamed: AppendMenu interprets
       metacharacters, and a label is data, not a menu program. */
    CopyCStringToPascal("x", label);
    AppendMenu(menu, label);
    CopyCStringToPascal(text, label);
    SetMenuItemText(menu, item, label);
    if (!enabled) {
        DisableMenuItem(menu, item);
    }
}

/* Both popups from the catalog: distinct providers, then the chosen
   provider's rows. The model the Send uses is g_row_sel, a CATALOG
   index; the filtered list maps popup items back to it. */
static void rebuild_popups(void)
{
    MenuRef provider_menu = popup_menu(g_provider_popup,
                                       kChatProvidersMenuID);
    MenuRef model_menu = popup_menu(g_model_popup, kChatModelsMenuID);
    int i;

    if (provider_menu == NULL || model_menu == NULL) {
        strcpy(g_status, "A popup menu resource is missing (136/137)");
        return;
    }
    g_provider_count = chat_catalog_providers(
        g_models, g_model_count, g_providers, kChatMaxModels);
    if (g_provider_sel >= g_provider_count) {
        g_provider_sel = 0;
    }

    while (CountMenuItems(provider_menu) > 0) {
        DeleteMenuItem(provider_menu, 1);
    }
    for (i = 0; i < g_provider_count; ++i) {
        fill_menu_item(provider_menu, (short)(i + 1), g_providers[i],
                       true);
    }
    if (g_provider_count == 0) {
        fill_menu_item(provider_menu, 1, "(none)", true);
    }

    /* The chosen provider's rows, serving first choice. */
    g_filtered_count = 0;
    g_filtered_sel = -1;
    for (i = 0; i < g_model_count; ++i) {
        if (g_provider_count == 0
            || strcmp(g_models[i].provider,
                      g_providers[g_provider_sel]) == 0) {
            g_filtered[g_filtered_count] = i;
            if (g_filtered_sel < 0
                && strcmp(g_models[i].state, "serving") == 0) {
                g_filtered_sel = g_filtered_count;
            }
            ++g_filtered_count;
        }
    }
    g_row_sel = g_filtered_sel >= 0 ? g_filtered[g_filtered_sel] : -1;

    while (CountMenuItems(model_menu) > 0) {
        DeleteMenuItem(model_menu, 1);
    }
    for (i = 0; i < g_filtered_count; ++i) {
        const ChatModelRow *row = &g_models[g_filtered[i]];
        char text[64];

        if (strcmp(row->state, "serving") == 0) {
            snprintf(text, sizeof text, "%.40s", row->label);
        } else {
            snprintf(text, sizeof text, "%.30s (%.14s)",
                     row->label, row->state);
        }
        fill_menu_item(model_menu, (short)(i + 1), text,
                       strcmp(row->state, "serving") == 0);
    }
    if (g_filtered_count == 0) {
        fill_menu_item(model_menu, 1, "(ask the other Mac)", true);
    }

    if (g_provider_popup != NULL) {
        SetControlMaximum(g_provider_popup,
                          CountMenuItems(provider_menu));
        SetControlValue(g_provider_popup, (short)(g_provider_sel + 1));
        if (g_visible) {
            Draw1Control(g_provider_popup);
        }
    }
    if (g_model_popup != NULL) {
        SetControlMaximum(g_model_popup, CountMenuItems(model_menu));
        SetControlValue(g_model_popup,
                        (short)(g_filtered_sel >= 0
                                    ? g_filtered_sel + 1 : 1));
        if (g_visible) {
            Draw1Control(g_model_popup);
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
        rebuild_popups();
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

static void send_prompt(void)
{
    char prompt[kChatPromptMax + 1];
    char err[96];

    if (prompt_size() == 0) {
        return;
    }
    if (prompt_size() > kChatPromptMax) {
        strcpy(g_status, "The prompt is longer than 512 characters");
        inval(&g_r.status);
        return;
    }
    if (g_row_sel < 0 || g_row_sel >= g_model_count
        || strcmp(g_models[g_row_sel].state, "serving") != 0) {
        strcpy(g_status, "Pick a serving model first");
        inval(&g_r.status);
        return;
    }
    prompt_text(prompt, sizeof prompt);
    if (now_wire_chat_send(g_models[g_row_sel].model, prompt,
                           err, sizeof err) != 0) {
        snprintf(g_status, sizeof g_status, "%.120s", err);
        inval(&g_r.status);
        return;
    }
    chat_transcript_add(&g_transcript, "> ", prompt);
    chat_transcript_begin_answer(&g_transcript);
    prompt_clear();
    g_streaming = true;
    g_pinned = true;
    g_top = max_top();
    retitle_send();
    sync_scrollbar();
    /* Accepted-and-silent is the stretch that reads as a hang; say
       who we are waiting for until the first delta clears it. */
    snprintf(g_status, sizeof g_status, "Waiting for %.40s...",
             g_models[g_row_sel].label);
    inval(&g_r.status);
    inval(&g_r.transcript);
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
    send_prompt();
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
    /* A fresh page deserves a fresh catalog: the host's providers may
       have changed since the last ask (metal, 2026-08-02: a runtime
       started after the first ask stayed invisible until relaunch). */
    if (conn_phase() == kConnConnected) {
        ask_catalog();
    }
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
    g_provider_popup = NewControl(owner, &g_r.provider_popup, text, false,
                                  popupTitleLeftJust, kChatProvidersMenuID,
                                  0, popupMenuProc, 0);
    g_model_popup = NewControl(owner, &g_r.model_popup, text, false,
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
    {
        Rect view;
        Rect dest;

        /* TENew samples the current port's text state. */
        SetPortWindowPort(owner);
        TextFont(g_font);
        TextSize(9);
        TextFace(normal);
        prompt_rects(&view, &dest);
        g_te = TENew(&dest, &view);
        if (g_te != NULL) {
            TEAutoView(true, g_te);
        }
    }
    if (g_provider_popup == NULL || g_model_popup == NULL
        || g_new_btn == NULL || g_send_btn == NULL
        || g_scroll == NULL || g_te == NULL
        || g_scroll_action_upp == NULL) {
        return memFullErr;
    }
    rebuild_popups();
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
    if (g_te != NULL) {
        TEDispose(g_te);              /* ours, not the window's */
        g_te = NULL;
    }
    g_provider_popup = NULL;
    g_model_popup = NULL;
    g_new_btn = NULL;
    g_send_btn = NULL;
    g_scroll = NULL;
    g_owner = NULL;
}

static void chat_show(Boolean visible)
{
    g_visible = visible;
    if (visible) {
        ShowControl(g_provider_popup);
        ShowControl(g_model_popup);
        ShowControl(g_new_btn);
        ShowControl(g_send_btn);
        ShowControl(g_scroll);
        if (g_te != NULL) {
            TEActivate(g_te);         /* the caret follows the page */
        }
        /* Every show, not once per connection: the host's providers
           change while this page is elsewhere (metal, 2026-08-02). */
        if (conn_phase() == kConnConnected) {
            ask_catalog();
        }
        /* Force the caches stale so the first draw is whole. */
        g_shown_lines = -1;
        g_shown_status[0] = '\0';
    } else {
        if (g_te != NULL) {
            TEDeactivate(g_te);       /* keys must not land in a hidden page */
        }
        HideControl(g_provider_popup);
        HideControl(g_model_popup);
        HideControl(g_new_btn);
        HideControl(g_send_btn);
        HideControl(g_scroll);
    }
}

static void chat_layout_op(const Rect *body)
{
    chat_layout_compute(body, &g_r);
    MoveControl(g_provider_popup, g_r.provider_popup.left,
                g_r.provider_popup.top);
    SizeControl(g_provider_popup,
                (short)(g_r.provider_popup.right - g_r.provider_popup.left),
                (short)(g_r.provider_popup.bottom - g_r.provider_popup.top));
    MoveControl(g_model_popup, g_r.model_popup.left, g_r.model_popup.top);
    SizeControl(g_model_popup,
                (short)(g_r.model_popup.right - g_r.model_popup.left),
                (short)(g_r.model_popup.bottom - g_r.model_popup.top));
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
    if (g_te != NULL) {
        Rect view;
        Rect dest;

        prompt_rects(&view, &dest);
        (*g_te)->viewRect = view;
        (*g_te)->destRect = dest;
        TECalText(g_te);
    }
    if (g_pinned) {
        g_top = max_top();
    }
    sync_scrollbar();
}

static void draw_transcript(void)
{
    Rect f = g_r.transcript;
    Rect inner = f;
    Rect band;
    RgnHandle saved = NewRgn();
    int fit = visible_lines();
    int lines = chat_transcript_count(&g_transcript);
    int i;
    short x = (short)(f.left + 5);
    short y = (short)(f.top + 4 + (kChatLineHeight - 3));

    /* Erase per ROW, never the pane in one go: BeginUpdate clips this
       to the damaged region, and a row's blank moment is microseconds
       where a whole-pane erase is a visible white flash at streaming
       cadence. Every pixel is still reconstructed from state - the
       bands above and below the rows included, for the reset case. */
    FrameRect(&f);
    InsetRect(&inner, 1, 1);
    if (saved != NULL) {
        GetClip(saved);
        ClipRect(&inner);
    }
    band = inner;
    band.bottom = (short)(f.top + 4);
    EraseRect(&band);
    band = inner;
    band.top = (short)(f.top + 4 + fit * kChatLineHeight);
    EraseRect(&band);
    TextFont(g_font);
    TextSize(9);
    TextFace(normal);
    for (i = 0; i < fit; ++i) {
        int line = g_top + i;

        band = inner;
        band.top = (short)(f.top + 4 + i * kChatLineHeight);
        band.bottom = (short)(band.top + kChatLineHeight);
        EraseRect(&band);
        if (line < lines) {
            draw_at(x, y, chat_transcript_line(&g_transcript, line));
        }
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

    /* Runs on page show and resize only: keystrokes never invalidate
       here, because TEKey draws its own insertion incrementally. */
    EraseRect(&f);
    FrameRect(&f);
    if (g_te != NULL) {
        TextFont(g_font);
        TextSize(9);
        TextFace(normal);
        TEUpdate(&(*g_te)->viewRect, g_te);
    }
}

static void chat_draw(void)
{
    draw_transcript();
    draw_status_line();
    draw_input();
    g_shown_lines = chat_transcript_count(&g_transcript);
    g_shown_open_len = g_transcript.feed.open_len;
    strncpy(g_shown_status, g_status, sizeof g_shown_status - 1);
}

static Boolean chat_click(const EventRecord *event, Point local)
{
    ControlRef control;
    ControlPartCode part;

    part = FindControl(local, g_owner, &control);
    if (control == g_provider_popup && part != 0) {
        /* Popup CDEFs run their own action; never hand them the pump. */
        if (TrackControl(g_provider_popup, local,
                         (ControlActionUPP)-1L) != 0) {
            int picked = GetControlValue(g_provider_popup) - 1;

            if (picked >= 0 && picked < g_provider_count
                && picked != g_provider_sel) {
                g_provider_sel = picked;
                rebuild_popups();     /* the model list follows */
            }
        }
        return true;
    }
    if (control == g_model_popup && part != 0) {
        if (TrackControl(g_model_popup, local,
                         (ControlActionUPP)-1L) != 0) {
            int picked = GetControlValue(g_model_popup) - 1;

            if (picked >= 0 && picked < g_filtered_count) {
                g_filtered_sel = picked;
                g_row_sel = g_filtered[picked];
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
        if (g_te != NULL) {
            /* TEClick tracks selection until mouse-up without pumping
               the wire - the same brief, unavoidable stall as a thumb
               drag, and documented with them. */
            TextFont(g_font);
            TextSize(9);
            TEClick(local, (event->modifiers & shiftKey) != 0, g_te);
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

    if (!g_visible) {
        return false;
    }
    if ((event->modifiers & cmdKey) != 0) {
        return false;                 /* menu equivalents stay the app's */
    }
    if (c == '\r' || c == 3) {
        /* Return sends when idle; while an answer streams it does
           nothing, so it can never cancel by accident - typing the
           next prompt meanwhile is allowed. */
        if (!g_streaming) {
            send_prompt();
        }
        return true;
    }
    if (c == 0x0B || c == 0x0C) {     /* page up / page down */
        scroll_to(g_top + (c == 0x0C ? visible_lines() - 1
                                     : -(visible_lines() - 1)), true);
        return true;
    }
    if (g_te != NULL) {
        /* The contract's cap, enforced at the door: a printable key at
           the limit is dropped unless it replaces a selection; editing
           keys always pass. TEKey draws its own change - no inval. */
        if ((unsigned char)c >= 0x20
            && prompt_size() >= kChatPromptMax
            && (*g_te)->selStart == (*g_te)->selEnd) {
            return true;
        }
        TextFont(g_font);
        TextSize(9);
        TEKey((short)c, g_te);
        return true;
    }
    return false;
}

static void chat_activate(Boolean active)
{
    if (g_provider_popup == NULL) {
        return;
    }
    if (active) {
        ActivateControl(g_provider_popup);
        ActivateControl(g_model_popup);
        ActivateControl(g_new_btn);
        ActivateControl(g_send_btn);
        ActivateControl(g_scroll);
        if (g_te != NULL && g_visible) {
            TEActivate(g_te);
        }
    } else {
        DeactivateControl(g_provider_popup);
        DeactivateControl(g_model_popup);
        DeactivateControl(g_new_btn);
        DeactivateControl(g_send_btn);
        DeactivateControl(g_scroll);
        if (g_te != NULL) {
            TEDeactivate(g_te);
        }
    }
}

static void chat_idle(void)
{
    int count;

    /* Nearly free: compare the caches, invalidate only what moved. */
    if (!g_visible) {
        return;
    }
    count = chat_transcript_count(&g_transcript);
    if (count != g_shown_lines
        || g_transcript.feed.open_len != g_shown_open_len) {
        int old_top = g_top;

        if (g_pinned) {
            g_top = max_top();
        }
        sync_scrollbar();
        /* The smallest honest damage. Rows shift only when the view
           scrolled or lost lines; otherwise a chunk touched the open
           tail line and maybe closed a line above it - just those. */
        if (g_shown_lines < 0 || g_top != old_top
            || count < g_shown_lines) {
            inval(&g_r.transcript);
        } else if (count > g_shown_lines) {
            inval_rows(g_shown_lines > 0 ? g_shown_lines - 1 : 0, count);
        } else {
            inval_rows(count > 0 ? count - 1 : 0, count);
        }
        g_shown_lines = count;
        g_shown_open_len = g_transcript.feed.open_len;
    }
    if (strcmp(g_status, g_shown_status) != 0) {
        inval(&g_r.status);
        strncpy(g_shown_status, g_status, sizeof g_shown_status - 1);
    }
    /* The caret. TEIdle is a blink check against TickCount - well
       within the idle budget while the page is up. */
    if (g_te != NULL) {
        TEIdle(g_te);
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
