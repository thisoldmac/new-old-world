#include "chat_module.h"
#include "control_kind.h"

#include <stdio.h>
#include <string.h>

#include "chat_layout.h"
#include "chat_model.h"
#include "chat_project_dialog.h"
#include "../core/contract.h"
#include "../core/pump.h"
#include "../core/wire.h"
#include "workshop_scene_text.h"

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

/* 136 belongs to the Photos size pop-up, which landed on main first;
   these two moved up rather than silently sharing its ID. A duplicate
   'MENU' number is a resource-fork collision Rez does not have to
   report and the loser of which simply never appears. */
enum {
    kChatModelsMenuID = 137,
    kChatProvidersMenuID = 138,
    /* 139-142 are spoken for (Browser, View, two icon suites); these
       two took the next free pair rather than sharing, for the reason
       stated above. */
    kChatModeMenuID = 143,
    kChatProjectMenuID = 144,
    kChatSkillsMenuID = 145
};

static WindowRef g_owner;
static Rect g_body;                   /* kept for prompt-growth relayout */
static ChatLayoutRects g_r;
static int g_prompt_lines = 1;        /* TE line count, clamped, laid out */
static ControlRef g_provider_popup;
static ControlRef g_model_popup;
static ControlRef g_mode_popup;
static ControlRef g_project_popup;
static ControlRef g_skills_popup;
static ControlRef g_sidebar_toggle;
static ControlRef g_new_btn;
static ControlRef g_send_btn;
static ControlRef g_scroll;
static ControlActionUPP g_scroll_action_upp;
static short g_font;

static ChatTranscript g_transcript;
/* Two-step, lazy: the provider popup holds the providers answer; the
   model popup holds ONLY the selected provider's models, asked when it
   is selected and accumulated page by page (the wire follows `more`
   from here). What a send carries is the selected row's REF. */
static ChatProviderRow g_providers[kChatMaxProviders];
static int g_provider_count;
static int g_provider_sel;
static ChatModelRow g_models[kChatMaxModels];
static int g_model_count;
static int g_model_sel = -1;
static char g_models_provider[25];    /* whose models are loading/loaded */
static Boolean g_models_loading;
static Boolean g_asked_catalog;

/* The sessions half of the page. Rosters are PAGES the host mints refs
   for, held only as long as the connection: a ref is a promise about
   one link, and reconnecting mints new ones. */
static ChatRosterRow g_chats[kChatMaxChats];
static int g_chat_count;
static int g_chat_sel = -1;           /* index into g_chats, or -1 */
static int g_chat_top;                /* first visible sidebar row */
/* Three states, because "nobody has asked" and "asked and heard
   nothing back" are different things and only one of them is worth
   showing a person a spinner for. The wire declares an unanswered ask
   dead after 15 seconds (kChatAskTimeoutTicks) and reports it as
   kChatAnswerError; without this the panel sat on "(asking...)"
   forever, which reads as a hang and was exactly what the first build
   on metal showed. */
enum {
    kChatListIdle = 0,
    kChatListLoading = 1,
    kChatListUnanswered = 2
};
static int g_chats_state;
/* The page WANTS its listings; when it gets to ask for them is the
   wire's business. See ask_when_free. */
static Boolean g_want_lists;
static Boolean g_want_catalog;
static Boolean g_want_history;
/* The next roster answer REPLACES the rows rather than appending: set
   by every fresh ask, consumed by the first page. The rows themselves
   stay drawn until then — clearing them at the ask put "(asking...)"
   over a list the person was reading. */
static Boolean g_roster_restart;
static ChatProjectRow g_projects[kChatMaxProjects];
static int g_project_count;
/* A create was sent; the next chat.result that lands is its answer,
   and an ok one means the roster moved. */
static Boolean g_created_project;
/* The loadable skills, listed once per connection: the catalogue is
   part of the app bundle over there and does not move under a running
   host. Choosing one TYPES its command into the prompt - visible,
   editable, sent by the person - so the popup adds no second loading
   path beside the slash the host already serves. */
static ChatSkillRow g_skills[kChatMaxSkills];
static int g_skill_count;
static Boolean g_want_skills;
static Boolean g_sidebar_shown = true;
/* What this turn may do. Build is NOT the default: the safe tier is the
   one that changes nothing, and the host reads an absent mode the same
   way — one rule, agreed on both sides rather than defaulted twice. */
static const char *const kChatModes[] = { "chat", "plan", "build" };
static int g_mode_sel;                /* index into kChatModes */
/* History paging: how many rows of the open chat have been taken from
   its newest end, and whether older ones remain. */
static int g_history_taken;
static Boolean g_history_more;

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

/* The page's shape, in one place. Every caller of the layout reads this
   rather than assembling its own spec — two spellings of "is the
   sidebar open" is how a click lands on a row a draw never made. */
static ChatLayoutSpec layout_spec(void)
{
    ChatLayoutSpec spec;

    spec.sidebar_shown = g_sidebar_shown;
    spec.prompt_lines = g_prompt_lines;
    return spec;
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

static void prompt_grew_or_shrank(void);

static void prompt_rects(Rect *view, Rect *dest)
{
    *view = g_r.input;
    InsetRect(view, 4, 3);
    /* Destination matches the view's width, so TE wraps at the well's
       edge; the well itself grows with the line count (layout), and
       past the cap TEAutoView scrolls the caret's line into sight. */
    *dest = *view;
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
    prompt_grew_or_shrank();          /* a grown well shrinks back */
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

static void rebuild_provider_popup(void)
{
    MenuRef menu = popup_menu(g_provider_popup, kChatProvidersMenuID);
    int i;

    if (menu == NULL) {
        strcpy(g_status, "A popup menu resource is missing (138)");
        return;
    }
    if (g_provider_sel >= g_provider_count) {
        g_provider_sel = 0;
    }
    while (CountMenuItems(menu) > 0) {
        DeleteMenuItem(menu, 1);
    }
    for (i = 0; i < g_provider_count; ++i) {
        const ChatProviderRow *row = &g_providers[i];
        char text[64];

        if (strcmp(row->state, "serving") == 0) {
            snprintf(text, sizeof text, "%.40s", row->label);
        } else {
            snprintf(text, sizeof text, "%.30s (%.14s)",
                     row->label, row->state);
        }
        fill_menu_item(menu, (short)(i + 1), text,
                       strcmp(row->state, "serving") == 0);
    }
    if (g_provider_count == 0) {
        fill_menu_item(menu, 1, "(none)", true);
    }
    if (g_provider_popup != NULL) {
        SetControlMaximum(g_provider_popup, CountMenuItems(menu));
        SetControlValue(g_provider_popup, (short)(g_provider_sel + 1));
        if (g_visible) {
            Draw1Control(g_provider_popup);
        }
    }
}

static void rebuild_model_popup(void)
{
    MenuRef menu = popup_menu(g_model_popup, kChatModelsMenuID);
    int i;

    if (menu == NULL) {
        strcpy(g_status, "A popup menu resource is missing (137)");
        return;
    }
    if (g_model_sel >= g_model_count) {
        g_model_sel = g_model_count > 0 ? 0 : -1;
    }
    if (g_model_sel < 0 && g_model_count > 0) {
        g_model_sel = 0;
    }
    while (CountMenuItems(menu) > 0) {
        DeleteMenuItem(menu, 1);
    }
    for (i = 0; i < g_model_count; ++i) {
        fill_menu_item(menu, (short)(i + 1), g_models[i].label, true);
    }
    if (g_model_count == 0) {
        fill_menu_item(menu, 1,
                       g_models_loading ? "(asking...)"
                                        : "(pick a provider)",
                       false);
    }
    if (g_model_popup != NULL) {
        SetControlMaximum(g_model_popup, CountMenuItems(menu));
        SetControlValue(g_model_popup,
                        (short)(g_model_sel >= 0 ? g_model_sel + 1 : 1));
        if (g_visible) {
            Draw1Control(g_model_popup);
        }
    }
}

/* The skills pop-up: item 1 is the label the closed popup shows, the
   rows are the commands. Dimmed until the roster arrives - an empty
   menu that drops down to nothing reads as a broken control. */
static void rebuild_skills_popup(void)
{
    MenuRef menu = popup_menu(g_skills_popup, kChatSkillsMenuID);
    int i;

    if (menu == NULL) {
        return;
    }
    while (CountMenuItems(menu) > 0) {
        DeleteMenuItem(menu, 1);
    }
    fill_menu_item(menu, 1, "Skills", true);
    for (i = 0; i < g_skill_count; ++i) {
        fill_menu_item(menu, (short)(i + 2), g_skills[i].command, true);
    }
    if (g_skills_popup != NULL) {
        SetControlMaximum(g_skills_popup, CountMenuItems(menu));
        SetControlValue(g_skills_popup, 1);
        HiliteControl(g_skills_popup,
                      (short)(g_skill_count > 0 ? 0 : 255));
        if (g_visible) {
            Draw1Control(g_skills_popup);
        }
    }
}

/* The project pop-up: "No project" first, always, then the host's
   roster. Item 1 is the decline, so a person can always get out of a
   project without finding one to switch to. */
static void rebuild_project_popup(void)
{
    MenuRef menu = popup_menu(g_project_popup, kChatProjectMenuID);
    int i;
    int current = 0;

    if (menu == NULL) {
        return;
    }
    while (CountMenuItems(menu) > 0) {
        DeleteMenuItem(menu, 1);
    }
    fill_menu_item(menu, 1, "No project", true);
    for (i = 0; i < g_project_count; ++i) {
        char text[64];

        /* Where its code lives, on the row that chooses it. "here" is
           this machine, because at this keyboard "guest" is a word
           about somebody else's. */
        if (strcmp(g_projects[i].home, "guest") == 0) {
            snprintf(text, sizeof text, "%.40s (here)", g_projects[i].label);
        } else if (strcmp(g_projects[i].home, "host") == 0) {
            snprintf(text, sizeof text, "%.40s (Other Mac)",
                     g_projects[i].label);
        } else {
            snprintf(text, sizeof text, "%.40s", g_projects[i].label);
        }
        fill_menu_item(menu, (short)(i + 2), text, true);
        if (g_projects[i].current) {
            current = i + 1;
        }
    }
    /* Last, after a separator: the one row that is a verb. */
    fill_menu_item(menu, (short)(g_project_count + 2), "-", false);
    fill_menu_item(menu, (short)(g_project_count + 3),
                   "New Project...", true);
    if (g_project_popup != NULL) {
        SetControlMaximum(g_project_popup, CountMenuItems(menu));
        SetControlValue(g_project_popup, (short)(current + 1));
        if (g_visible) {
            Draw1Control(g_project_popup);
        }
    }
}

/* Ask for the saved chats, from the top. The roster is metadata, so
   this is cheap enough to re-ask whenever the list could have moved -
   after a send, a new chat, or a filing. */
static void ask_chats(void)
{
    char err[96];

    if (now_wire_chat_chats(0, err, sizeof err) != 0) {
        snprintf(g_status, sizeof g_status, "%.120s", err);
        g_chats_state = kChatListUnanswered;
        inval(&g_r.status);
        inval(&g_r.sidebar);
        return;
    }
    g_roster_restart = true;
    g_chats_state = kChatListLoading;
}

static void ask_catalog(void);
static void ask_history(void);

/* Every listing this page wants is recorded as a WANT and issued here,
   one at a time, only when the wire's single ask slot is free. The
   want sites used to call the wire directly, and a second ask ORPHANS
   the first: its answer arrives carrying a kind the pending no longer
   names, is dropped as stale, and the deadline that would have
   reported the silence goes with it — so the sidebar reads
   "(asking...)" forever. Measured three ways on the emulator
   (2026-08-19): the projects ask stomping the roster, the catalog ask
   stomping it, and New Chat stomping its own reset. */
static void ask_when_free(void)
{
    if (now_wire_chat_ask_pending() || now_wire_chat_turn_active()) {
        return;
    }
    if (g_want_history) {
        /* First: the person just opened a chat and is looking at an
           empty transcript. */
        g_want_history = false;
        ask_history();
        return;
    }
    if (g_want_catalog) {
        if (conn_phase() != kConnConnected) {
            return;                   /* keep the want for the reconnect */
        }
        g_want_catalog = false;
        ask_catalog();
        return;
    }
    if (g_want_lists) {
        if (g_chats_state == kChatListLoading) {
            return;                   /* a roster page is already in flight */
        }
        g_want_lists = false;
        ask_chats();
        return;
    }
    if (g_want_skills && conn_phase() == kConnConnected) {
        char err[96];

        g_want_skills = false;
        (void)now_wire_chat_skills(err, sizeof err);
    }
}

static void ask_projects(void)
{
    char err[96];

    g_project_count = 0;
    if (now_wire_chat_projects(0, err, sizeof err) != 0) {
        return;                       /* the popup simply stays as it was */
    }
}

/* One page of the open chat's history, oldest-first WITHIN the page, so
   it can be appended to the transcript in reading order. Asked only
   when a person opens a chat or scrolls past what has arrived: this is
   the lazy half, and asking for it eagerly would put a whole
   conversation on a slow wire nobody asked to read. */
static void ask_history(void)
{
    char err[96];

    if (now_wire_chat_history((long)g_history_taken, err, sizeof err) != 0) {
        snprintf(g_status, sizeof g_status, "%.120s", err);
        inval(&g_r.status);
    }
}

/* The mode popup is a PROMISE about what a turn may do, so it follows
   the selected provider's reach rather than standing on its own. A
   text-only relay gets a dimmed popup and a status line saying why —
   offering Build to a model with no hands is the thing that sent a
   person into build mode against a model that could not build (metal,
   2026-08-19). */
static void sync_mode_popup(void)
{
    Boolean has_tools = true;

    if (g_provider_sel >= 0 && g_provider_sel < g_provider_count) {
        has_tools = strcmp(g_providers[g_provider_sel].tools, "none") != 0;
    }
    if (g_mode_popup == NULL) {
        return;
    }
    HiliteControl(g_mode_popup, (short)(has_tools ? 0 : 255));
    if (!has_tools) {
        /* Chat is what the host will run for it anyway: a turn with no
           tools is the tier that changes nothing, whatever this popup
           was left showing. */
        g_mode_sel = 0;
        SetControlValue(g_mode_popup, 1);
    }
}

/* Ask for the selected provider's models, from the top. Lazy by
   design: nothing is listed until somebody selects it. */
static void ask_models(void)
{
    char err[96];

    g_model_count = 0;
    g_model_sel = -1;
    g_models_loading = false;
    g_models_provider[0] = '\0';
    if (g_provider_sel < 0 || g_provider_sel >= g_provider_count
        || strcmp(g_providers[g_provider_sel].state, "serving") != 0) {
        rebuild_model_popup();
        return;
    }
    /* What this provider can actually DO, on the line under the
       transcript, the moment it is picked. The host puts a provider's
       REACH at the front of its detail - two of them cannot use tools
       at all - and a person at this machine otherwise learns that from
       the model apologising a turn later. Transient by design: the
       first delta of the next answer clears it. */
    if (g_providers[g_provider_sel].detail[0] != '\0') {
        snprintf(g_status, sizeof g_status, "%.120s",
                 g_providers[g_provider_sel].detail);
        inval(&g_r.status);
    }
    strncpy(g_models_provider, g_providers[g_provider_sel].provider,
            sizeof g_models_provider - 1);
    g_models_provider[sizeof g_models_provider - 1] = '\0';
    if (now_wire_chat_model_page(g_models_provider, 0,
                                 err, sizeof err) != 0) {
        snprintf(g_status, sizeof g_status, "%.120s", err);
        inval(&g_r.status);
        return;
    }
    g_models_loading = true;
    rebuild_model_popup();
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
    case kChatAnswerProviders: {
        char kept[25];

        /* Keep the person's provider choice across a re-ask when it
           still exists; otherwise fall to the first serving one. */
        kept[0] = '\0';
        if (g_provider_sel >= 0 && g_provider_sel < g_provider_count) {
            strcpy(kept, g_providers[g_provider_sel].provider);
        }
        g_provider_count = chat_parse_providers(reply, g_providers,
                                                kChatMaxProviders);
        if (g_provider_count < 0) {
            g_provider_count = 0;
        }
        g_provider_sel = -1;
        {
            int i;

            for (i = 0; i < g_provider_count; ++i) {
                if (kept[0] != '\0'
                    && strcmp(g_providers[i].provider, kept) == 0) {
                    g_provider_sel = i;
                    break;
                }
            }
            for (i = 0; g_provider_sel < 0 && i < g_provider_count; ++i) {
                if (strcmp(g_providers[i].state, "serving") == 0) {
                    g_provider_sel = i;
                }
            }
        }
        if (g_provider_sel < 0) {
            g_provider_sel = 0;
        }
        rebuild_provider_popup();
        ask_models();                 /* lazy step two, for the selection */
        g_status[0] = '\0';
        break;
    }
    case kChatAnswerModels: {
        ChatModelRow page[kChatPageRows];
        char from[25];
        int more = 0;
        int n = chat_parse_models(reply, page, kChatPageRows, &more,
                                  from, sizeof from);
        int i;

        /* A page for a provider the person has switched away from is
           stale, not content. */
        if (n < 0 || strcmp(from, g_models_provider) != 0) {
            break;
        }
        for (i = 0; i < n && g_model_count < kChatMaxModels; ++i) {
            g_models[g_model_count++] = page[i];
        }
        if (more && g_model_count < kChatMaxModels) {
            char err[96];

            /* The pagination loop, invisible to the person: keep
               asking until the host says done. */
            if (now_wire_chat_model_page(g_models_provider,
                                         (long)g_model_count,
                                         err, sizeof err) != 0) {
                g_models_loading = false;
            }
        } else {
            g_models_loading = false;
        }
        rebuild_model_popup();
        break;
    }
    case kChatAnswerRoster: {
        int more = 0;
        int n;
        int i;

        if (g_roster_restart) {
            /* The first page of a fresh roster replaces what was
               drawn; later pages of the same listing append. */
            g_roster_restart = false;
            g_chat_count = 0;
            g_chat_sel = -1;
            g_chat_top = 0;
        }
        n = chat_parse_roster(reply, &g_chats[g_chat_count],
                              kChatMaxChats - g_chat_count, &more);
        if (n < 0) {
            g_chats_state = kChatListIdle;
            break;
        }
        for (i = 0; i < n; ++i) {
            if (g_chats[g_chat_count + i].current) {
                g_chat_sel = g_chat_count + i;
            }
        }
        g_chat_count += n;
        if (more && g_chat_count < kChatMaxChats) {
            char err[96];

            /* The pagination loop, invisible to the person - the models
               loop's shape, for the same reason. */
            if (now_wire_chat_chats((long)g_chat_count, err,
                                    sizeof err) != 0) {
                g_chats_state = kChatListIdle;
            }
        } else {
            g_chats_state = kChatListIdle;
            /* The roster is done, so the slot is free: now the projects.
               Chained rather than parallel, for the reason stated at the
               ask site. */
            if (g_project_count == 0) {
                ask_projects();
            }
        }
        inval(&g_r.sidebar);
        break;
    }
    case kChatAnswerProjects: {
        int more = 0;
        int n = chat_parse_projects(reply, &g_projects[g_project_count],
                                    kChatMaxProjects - g_project_count,
                                    &more);

        if (n < 0) {
            break;
        }
        g_project_count += n;
        if (more && g_project_count < kChatMaxProjects) {
            char err[96];

            (void)now_wire_chat_projects((long)g_project_count, err,
                                         sizeof err);
        }
        rebuild_project_popup();
        break;
    }
    case kChatAnswerSkills: {
        int more = 0;
        int n = chat_parse_skills(reply, g_skills, kChatMaxSkills, &more);

        if (n < 0) {
            break;
        }
        g_skill_count = n;            /* one page carries the tree today */
        rebuild_skills_popup();
        break;
    }
    case kChatAnswerTranscript: {
        ChatHistoryRow rows[kChatHistoryRows];
        int more = 0;
        int n = chat_parse_history(reply, rows, kChatHistoryRows, &more);
        int i;

        if (n < 0) {
            break;
        }
        /* A page is the NEWEST rows not yet seen, so it appends to what
           is already drawn. Older pages arrive only if somebody asks
           for them, and this ring keeps the newest 300 lines whatever
           order they came in. */
        for (i = 0; i < n; ++i) {
            chat_transcript_add(&g_transcript, rows[i].kind,
                                rows[i].kind == kChatLinePerson ? "> "
                                    : (rows[i].kind == kChatLineMarker
                                       ? "* " : NULL),
                                rows[i].text);
        }
        g_history_taken += n;
        g_history_more = more != 0;
        g_pinned = true;
        inval(&g_r.transcript);
        break;
    }
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
        chat_transcript_add(&g_transcript, kChatLineMarker, "* ", reply);
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
            chat_transcript_add(&g_transcript, kChatLineMarker, "* ", line);
        }
        g_streaming = false;
        g_status[0] = '\0';
        retitle_send();
        inval(&g_r.status);
        if (g_created_project) {
            /* The create's answer, and the slot just freed: the roster
               moved on the host, so re-list rather than guessing. */
            g_created_project = false;
            if (ok) {
                g_project_count = 0;
                ask_projects();
            }
        }
        break;
    }
    case kChatAnswerError:
        /* An unanswered LISTING is not a dead turn: it means this host
           said nothing, which the contract reads as one that predates
           the family. The panel has to stop claiming to be asking. */
        /* Any unanswered ask ends the listing's spinner, whichever kind
           timed out. The wire has ONE pending slot, so a silence
           reported against a later ask is silence for this one too, and
           a panel that kept claiming to be asking would be the same lie
           by a longer route. */
        if (g_chats_state == kChatListLoading) {
            g_chats_state = kChatListUnanswered;
            inval(&g_r.sidebar);
        }
        chat_transcript_end_answer(&g_transcript);
        chat_transcript_add(&g_transcript, kChatLineMarker, "* ", reply);
        g_streaming = false;
        g_status[0] = '\0';
        retitle_send();
        inval(&g_r.status);
        break;
    default:
        break;
    }
    /* Mutation only - the header's promise. The idle pass pins the
       tail, syncs the scrollbar and computes the damage; pinning HERE
       made idle's before/after top comparison read "nothing scrolled"
       and the history above the tail was never repainted (metal,
       2026-08-02: new chunks rewrote the bottom rows in place). */
}

/* --- actions ------------------------------------------------------------ */

static void ask_catalog(void)
{
    char err[96];

    if (now_wire_chat_providers(err, sizeof err) != 0) {
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
    if (g_model_sel < 0 || g_model_sel >= g_model_count) {
        strcpy(g_status, "Pick a serving model first");
        inval(&g_r.status);
        return;
    }
    prompt_text(prompt, sizeof prompt);
    /* The mode rides every send. It is the popup's value and nothing
       else — the host gates on it, so a page that sent one thing and
       showed another would be lying about what the turn may do. */
    if (now_wire_chat_send_mode(g_models[g_model_sel].ref, prompt,
                                kChatModes[g_mode_sel],
                                err, sizeof err) != 0) {
        snprintf(g_status, sizeof g_status, "%.120s", err);
        inval(&g_r.status);
        return;
    }
    chat_transcript_add(&g_transcript, kChatLinePerson, "> ", prompt);
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
             g_models[g_model_sel].label);
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
    g_history_taken = 0;
    g_history_more = false;
    sync_scrollbar();
    inval(&g_r.transcript);
    /* The chat just left is saved and listed, and this one is now the
       current row — both facts come from the host, so re-ask rather
       than guessing at the list. Recorded as wants, never asked here:
       the reset above holds the wire's one ask slot until its result
       lands, and asking now orphaned it (the "(asking...)" wedge). */
    g_want_lists = true;
    /* A fresh page deserves a fresh catalog: the host's providers may
       have changed since the last ask (metal, 2026-08-02: a runtime
       started after the first ask stayed invisible until relaunch). */
    g_want_catalog = true;
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
    g_body = *body;
    g_prompt_lines = 1;
    {
        ChatLayoutSpec spec = layout_spec();

        chat_layout_compute(body, &spec, &g_r);
    }
    if (g_font == 0) {
        Str255 geneva;

        CopyCStringToPascal("Geneva", geneva);
        GetFNum(geneva, &g_font);
    }
    chat_transcript_reset(&g_transcript);

    text[0] = 0;
    g_provider_popup = now_control_new(owner, &g_r.provider_popup, text, false,
                                  popupTitleLeftJust, kChatProvidersMenuID,
                                  0, popupMenuProc, 0);
    g_model_popup = now_control_new(owner, &g_r.model_popup, text, false,
                               popupTitleLeftJust, kChatModelsMenuID, 0,
                               popupMenuProc, 0);
    g_mode_popup = now_control_new(owner, &g_r.mode_popup, text, false,
                              popupTitleLeftJust, kChatModeMenuID, 0,
                              popupMenuProc, 0);
    g_project_popup = now_control_new(owner, &g_r.project_popup, text, false,
                                 popupTitleLeftJust, kChatProjectMenuID, 0,
                                 popupMenuProc, 0);
    g_skills_popup = now_control_new(owner, &g_r.skills_popup, text, false,
                                popupTitleLeftJust, kChatSkillsMenuID, 0,
                                popupMenuProc, 0);
    /* The rail's own affordance, one page down: a bevel button whose
       title says which way it goes. */
    CopyCStringToPascal("<", text);
    g_sidebar_toggle = now_control_new(owner, &g_r.sidebar_toggle, text,
                                  false, 0, 0, 1, pushButProc, 0);
    CopyCStringToPascal("New Chat", text);
    g_new_btn = now_control_new(owner, &g_r.new_button, text, false, 0, 0, 1,
                           pushButProc, 0);
    CopyCStringToPascal("Send", text);
    g_send_btn = now_control_new(owner, &g_r.send_button, text, false, 0, 0, 1,
                            pushButProc, 0);
    g_scroll_action_upp = NewControlActionUPP(scroll_action);
    g_scroll = now_control_new(owner, &g_r.scrollbar, text, false, 0, 0, 0,
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
        || g_mode_popup == NULL || g_project_popup == NULL
        || g_skills_popup == NULL
        || g_sidebar_toggle == NULL
        || g_new_btn == NULL || g_send_btn == NULL
        || g_scroll == NULL || g_te == NULL
        || g_scroll_action_upp == NULL) {
        return memFullErr;
    }
    rebuild_provider_popup();
    rebuild_model_popup();
    rebuild_project_popup();
    rebuild_skills_popup();
    SetControlValue(g_mode_popup, (short)(g_mode_sel + 1));
    sync_mode_popup();
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
    g_mode_popup = NULL;
    g_project_popup = NULL;
    g_sidebar_toggle = NULL;
    g_new_btn = NULL;
    g_send_btn = NULL;
    g_scroll = NULL;
    g_owner = NULL;
}

static void chat_show(Boolean visible)
{
    g_visible = visible;
    if (visible) {
        /* Asked on SHOW rather than on create: a page nobody has opened
           has no business spending a slow wire on a listing, and the
           roster can have moved since the last time it was open.

           ONE ASK AT A TIME, AND THIS PAGE DOES NOT DECIDE WHEN. The
           wire keeps a single pending slot for this family (wire.c ::
           g_chatask), so a second ask issued before the first is
           answered ORPHANS it: the answer arrives carrying a kind the
           pending no longer names and is discarded as stale, and the
           deadline that would have reported the silence went with it —
           so the sidebar reads "(asking...)" forever, which is the
           failure a person sees. Measured twice on the emulator
           (2026-08-19): first the projects ask stomping the roster, then
           the CATALOG ask stomping it, because opening the page asks for
           both. So the page only ever records that it wants the
           listings, and asks when the wire is free. */
        g_want_lists = true;
        ShowControl(g_provider_popup);
        ShowControl(g_model_popup);
        ShowControl(g_mode_popup);
        ShowControl(g_project_popup);
        ShowControl(g_skills_popup);
        if (g_skill_count == 0) {
            g_want_skills = true;
        }
        ShowControl(g_sidebar_toggle);
        ShowControl(g_new_btn);
        ShowControl(g_send_btn);
        ShowControl(g_scroll);
        if (g_te != NULL) {
            TEActivate(g_te);         /* the caret follows the page */
        }
        /* Every show, not once per connection: the host's providers
           change while this page is elsewhere (metal, 2026-08-02).
           A want, not an ask — the roster may already be in flight. */
        g_want_catalog = true;
        /* Force the caches stale so the first draw is whole. */
        g_shown_lines = -1;
        g_shown_status[0] = '\0';
    } else {
        if (g_te != NULL) {
            TEDeactivate(g_te);       /* keys must not land in a hidden page */
        }
        HideControl(g_provider_popup);
        HideControl(g_model_popup);
        HideControl(g_mode_popup);
        HideControl(g_project_popup);
        HideControl(g_skills_popup);
        HideControl(g_sidebar_toggle);
        HideControl(g_new_btn);
        HideControl(g_send_btn);
        HideControl(g_scroll);
    }
}

static void apply_layout(void)
{
    ChatLayoutSpec spec = layout_spec();

    chat_layout_compute(&g_body, &spec, &g_r);
    MoveControl(g_provider_popup, g_r.provider_popup.left,
                g_r.provider_popup.top);
    SizeControl(g_provider_popup,
                (short)(g_r.provider_popup.right - g_r.provider_popup.left),
                (short)(g_r.provider_popup.bottom - g_r.provider_popup.top));
    MoveControl(g_model_popup, g_r.model_popup.left, g_r.model_popup.top);
    SizeControl(g_model_popup,
                (short)(g_r.model_popup.right - g_r.model_popup.left),
                (short)(g_r.model_popup.bottom - g_r.model_popup.top));
    MoveControl(g_sidebar_toggle, g_r.sidebar_toggle.left,
                g_r.sidebar_toggle.top);
    SizeControl(g_sidebar_toggle,
                (short)(g_r.sidebar_toggle.right - g_r.sidebar_toggle.left),
                (short)(g_r.sidebar_toggle.bottom - g_r.sidebar_toggle.top));
    MoveControl(g_mode_popup, g_r.mode_popup.left, g_r.mode_popup.top);
    SizeControl(g_mode_popup,
                (short)(g_r.mode_popup.right - g_r.mode_popup.left),
                (short)(g_r.mode_popup.bottom - g_r.mode_popup.top));
    MoveControl(g_project_popup, g_r.project_popup.left,
                g_r.project_popup.top);
    SizeControl(g_project_popup,
                (short)(g_r.project_popup.right - g_r.project_popup.left),
                (short)(g_r.project_popup.bottom - g_r.project_popup.top));
    MoveControl(g_skills_popup, g_r.skills_popup.left,
                g_r.skills_popup.top);
    SizeControl(g_skills_popup,
                (short)(g_r.skills_popup.right - g_r.skills_popup.left),
                (short)(g_r.skills_popup.bottom - g_r.skills_popup.top));
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
        TESelView(g_te);              /* keep the caret's line in sight */
    }
    if (g_pinned) {
        g_top = max_top();
    }
    sync_scrollbar();
}

static void chat_layout_op(const Rect *body)
{
    g_body = *body;
    apply_layout();
}

/* After any edit that can change TE's line count. The well grows and
   the page above it moves - once per line boundary, never per key. */
static void prompt_grew_or_shrank(void)
{
    int lines = g_te != NULL ? (*g_te)->nLines : 1;
    Rect moved;

    if (lines < 1) {
        lines = 1;
    }
    if (lines > kChatPromptMaxLines) {
        lines = kChatPromptMaxLines;
    }
    if (lines == g_prompt_lines) {
        return;
    }
    g_prompt_lines = lines;
    apply_layout();
    /* Everything below the popups moved or resized; the popup row did
       not. Honest full damage for a geometry change. */
    moved = g_body;
    moved.top = g_r.transcript.top;
    inval(&moved);
    g_shown_lines = -1;               /* the pane's rows all moved */
}

/* The transcript, walked once and rendered twice: a NULL writer draws
   the rows (erasing each band as it goes), a writer describes them. The
   visible window - g_top, the row count that fits, the model accessor -
   is computed here and only here, so the host is never told about a turn
   the person has scrolled past, and never told a different one. */
static void emit_transcript(const WorkshopSceneWriter *writer)
{
    Rect f = g_r.transcript;
    Rect inner = f;
    Rect band;
    RgnHandle saved = NewRgn();
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    RGBColor saved_back;
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
    if (writer != NULL) {
        workshop_scene_add(writer, kWorkshopScenePanel, "Transcript", &f,
                           true);
        InsetRect(&inner, 1, 1);
    } else {
        FrameRect(&f);
        InsetRect(&inner, 1, 1);
        if (saved != NULL) {
            GetClip(saved);
            ClipRect(&inner);
        }
        /* EraseRect erases to the port's CURRENT back color, not white - a
           themed back color (workshop_sidebar.c's pattern) left it tinted
           here, so transcript rows painted whatever the port last set. */
        GetBackColor(&saved_back);
        RGBBackColor(&white);
        band = inner;
        band.bottom = (short)(f.top + 4);
        EraseRect(&band);
        band = inner;
        band.top = (short)(f.top + 4 + fit * kChatLineHeight);
        EraseRect(&band);
        TextFont(g_font);
        TextSize(9);
        TextFace(normal);
    }
    for (i = 0; i < fit; ++i) {
        int line = g_top + i;

        band = inner;
        band.top = (short)(f.top + 4 + i * kChatLineHeight);
        band.bottom = (short)(band.top + kChatLineHeight);
        if (writer == NULL) {
            EraseRect(&band);
        }
        if (line < lines) {
            const char *text = chat_transcript_line(&g_transcript, line);

            if (writer != NULL) {
                workshop_scene_add(writer, kWorkshopSceneStaticText, text,
                                   &band, true);
            } else if (chat_transcript_line_kind(&g_transcript, line)
                           == kChatLinePerson) {
                /* The person's turns sit against the right edge - who is
                   speaking is visible at a glance, the modern transcript
                   shape drawn with plain QuickDraw. */
                short w = TextWidth(text, 0, (short)strlen(text));

                draw_at((short)(f.right - 5 - w), y, text);
            } else {
                draw_at(x, y, text);
            }
        }
        y = (short)(y + kChatLineHeight);
    }
    if (lines == 0) {
        char empty[80];
        char peer[40];

        conn_peer_label(peer, sizeof peer);
        if (g_model_count > 0) {
            snprintf(empty, sizeof empty, "Ask %.24s's model about this one.",
                     peer);
        } else {
            snprintf(empty, sizeof empty, "Waiting for %.24s's models...",
                     peer);
        }

        if (writer != NULL) {
            band = inner;
            band.top = (short)(f.top + 4);
            band.bottom = (short)(band.top + kChatLineHeight);
            workshop_scene_add(writer, kWorkshopSceneStaticText, empty,
                               &band, true);
        } else {
            draw_at(x, (short)(f.top + 16), empty);
        }
    }
    if (writer == NULL) {
        RGBBackColor(&saved_back);
    }
    if (saved != NULL) {
        if (writer == NULL) {
            SetClip(saved);
        }
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
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    RGBColor saved_back;

    /* Runs on page show and resize only: keystrokes never invalidate
       here, because TEKey draws its own insertion incrementally. */
    GetBackColor(&saved_back);
    RGBBackColor(&white);
    EraseRect(&f);
    RGBBackColor(&saved_back);
    FrameRect(&f);
    if (g_te != NULL) {
        TextFont(g_font);
        TextSize(9);
        TextFace(normal);
        TEUpdate(&(*g_te)->viewRect, g_te);
    }
}

/* The saved-chats panel: a framed white well of one-line rows, the
   rail's own shape. Drawn from state alone on the update event, like
   every other rectangle on this page — nothing here is drawn as a side
   effect of a click. */
static void draw_sidebar(void)
{
    RGBColor white = { 0xFFFF, 0xFFFF, 0xFFFF };
    RGBColor saved_back;
    int i;

    if (!g_sidebar_shown || g_r.sidebar.right <= g_r.sidebar.left) {
        return;
    }
    GetBackColor(&saved_back);
    RGBBackColor(&white);
    EraseRect(&g_r.sidebar);
    RGBBackColor(&saved_back);
    FrameRect(&g_r.sidebar);
    TextFont(g_font);
    TextSize(9);
    for (i = 0; i < g_r.sidebar_visible; ++i) {
        int index = g_chat_top + i;
        const Rect *row = &g_r.sidebar_rows[i];
        char line[64];

        if (index >= g_chat_count) {
            break;
        }
        TextFace(index == g_chat_sel ? bold : normal);
        /* One glyph for where it was typed. A chat a person wrote at
           the other Mac is the one they need warning about before they
           open it, and a whole word does not fit a 132-pixel row. */
        snprintf(line, sizeof line, "%s %.28s",
                 strcmp(g_chats[index].origin, "guest") == 0 ? "*" : "-",
                 g_chats[index].label);
        draw_at((short)(row->left + 3), (short)(row->bottom - 3), line);
        if (index == g_chat_sel) {
            /* The open one, inverted the way a list marks selection —
               ONCE, after the text, so the glyphs invert with the row.
               Inverting before and after cancelled out under srcOr and
               left white text on the white well: the selected row read
               as empty. */
            InvertRect(row);
        }
    }
    TextFace(normal);
    if (g_chat_count == 0) {
        const char *empty = "(no saved chats)";

        if (g_chats_state == kChatListLoading) {
            empty = "(asking...)";
        } else if (g_chats_state == kChatListUnanswered) {
            /* NOT "(no saved chats)": this side never heard back, and
               claiming the person has none would be inventing an answer
               out of silence. */
            empty = "(no answer)";
        }
        draw_at((short)(g_r.sidebar.left + 4),
                (short)(g_r.sidebar.top + 14), empty);
    }
}

static void chat_draw(void)
{
    emit_transcript(NULL);
    draw_sidebar();
    draw_status_line();
    draw_input();
    g_shown_lines = chat_transcript_count(&g_transcript);
    g_shown_open_len = g_transcript.feed.open_len;
    strncpy(g_shown_status, g_status, sizeof g_shown_status - 1);
}

static void chat_describe_scene(const WorkshopSceneWriter *writer)
{
    emit_transcript(writer);
    /* The saved-chats rows, so what a person can click something else
       can see. A list drawn with QuickDraw and absent from the scene is
       a control that exists for eyes only, which is the shape of gap
       the act plane keeps finding. */
    if (g_sidebar_shown) {
        int i;

        workshop_scene_add(writer, kWorkshopScenePanel, "Saved chats",
                           &g_r.sidebar, true);
        for (i = 0; i < g_r.sidebar_visible; ++i) {
            int index = g_chat_top + i;

            if (index >= g_chat_count) {
                break;
            }
            workshop_scene_add(writer, kWorkshopSceneStaticText,
                               g_chats[index].label,
                               &g_r.sidebar_rows[i], true);
        }
    }
    if (g_status[0] != '\0') {
        workshop_scene_add(writer, kWorkshopSceneStaticText, g_status,
                           &g_r.status, true);
    }
    /* The prompt well is a TextEdit record, not a control, so nothing
       else would mention it. Its contents are what the person is still
       typing; the rect is reported, the keystrokes are not. */
    workshop_scene_add(writer, kWorkshopScenePanel, "Prompt", &g_r.input,
                       true);
}

/* Edit>Copy: the transcript and the status line — the prompt's own
   keystrokes are deliberately not described above, so they are not
   copyable either; a person mid-sentence does not want Copy to hand
   someone else what they have not sent yet.

   Served by pointing this page's own describe_scene at a buffer
   instead of at the host, so what lands on the clipboard is by
   construction what the page describes, which is by construction what
   it drew. */
static long chat_copy_text(char *out, long cap)
{
    WorkshopSceneText sink;
    WorkshopSceneWriter writer;

    workshop_scene_text_begin(&sink, &writer, out, cap);
    chat_describe_scene(&writer);
    return workshop_scene_text_end(&sink);
}

/* Open the chat in sidebar slot `row`. The transcript is CLEARED and
   refilled from the host a page at a time: what was on screen belonged
   to the chat being left, and leaving it there would read as one
   conversation with a seam in it. */
static void open_chat(int row)
{
    char err[96];

    if (row < 0 || row >= g_chat_count || g_streaming) {
        if (g_streaming) {
            strcpy(g_status, "Stop the answer first");
            inval(&g_r.status);
        }
        return;
    }
    if (now_wire_chat_open(g_chats[row].ref, err, sizeof err) != 0) {
        snprintf(g_status, sizeof g_status, "%.120s", err);
        inval(&g_r.status);
        return;
    }
    g_chat_sel = row;
    chat_transcript_reset(&g_transcript);
    g_history_taken = 0;
    g_history_more = false;
    g_top = 0;
    g_pinned = true;
    inval(&g_r.transcript);
    inval(&g_r.sidebar);
    /* A want: the chat.open above holds the wire's one ask slot until
       its result lands, and asking for history now would orphan it. */
    g_want_history = true;
}

static void toggle_sidebar(void)
{
    Str255 text;

    g_sidebar_shown = !g_sidebar_shown;
    CopyCStringToPascal(g_sidebar_shown ? "<" : ">", text);
    SetControlTitle(g_sidebar_toggle, text);
    apply_layout();
    /* The whole body: the transcript changed width, so its wrapped
       lines and the panel beside it are both stale. */
    inval(&g_body);
    if (g_sidebar_shown && g_chat_count == 0
        && g_chats_state != kChatListLoading) {
        g_want_lists = true;
    }
}

static Boolean chat_click(const EventRecord *event, Point local)
{
    ControlRef control;
    ControlPartCode part;
    int row;

    part = FindControl(local, g_owner, &control);
    if (control == g_provider_popup && part != 0) {
        /* Popup CDEFs run their own action; never hand them the pump. */
        if (TrackControl(g_provider_popup, local,
                         (ControlActionUPP)-1L) != 0) {
            int picked = GetControlValue(g_provider_popup) - 1;

            if (picked >= 0 && picked < g_provider_count
                && picked != g_provider_sel) {
                g_provider_sel = picked;
                sync_mode_popup();
                ask_models();         /* lazy: listed on selection */
            }
        }
        return true;
    }
    if (control == g_model_popup && part != 0) {
        if (TrackControl(g_model_popup, local,
                         (ControlActionUPP)-1L) != 0) {
            int picked = GetControlValue(g_model_popup) - 1;

            if (picked >= 0 && picked < g_model_count) {
                g_model_sel = picked;
            }
        }
        return true;
    }
    if (control == g_mode_popup && part != 0) {
        if (TrackControl(g_mode_popup, local, (ControlActionUPP)-1L) != 0) {
            int picked = GetControlValue(g_mode_popup) - 1;

            if (picked >= 0
                && picked < (int)(sizeof kChatModes / sizeof kChatModes[0])) {
                g_mode_sel = picked;
            }
        }
        return true;
    }
    if (control == g_project_popup && part != 0) {
        short before = GetControlValue(g_project_popup);

        if (TrackControl(g_project_popup, local,
                         (ControlActionUPP)-1L) != 0) {
            int picked = GetControlValue(g_project_popup) - 1;
            char err[96];
            int ok;

            /* Item 1 is always the decline, so the index into the
               roster is one less than the item. */
            if (picked == 0) {
                ok = now_wire_chat_project("none", NULL, NULL, NULL,
                                           err, sizeof err) == 0;
            } else if (picked - 1 < g_project_count) {
                ok = now_wire_chat_project("select",
                                           g_projects[picked - 1].ref,
                                           NULL, NULL, err,
                                           sizeof err) == 0;
            } else if (picked == g_project_count + 2) {
                char name[48];
                char home[8];

                /* The verb row. The popup must not sit on it while the
                   dialog runs - it is not a state a person can be in. */
                SetControlValue(g_project_popup, before);
                Draw1Control(g_project_popup);
                ok = 1;
                if (now_chat_project_new(name, sizeof name,
                                         home, sizeof home)) {
                    ok = now_wire_chat_project("create", NULL, name, home,
                                               err, sizeof err) == 0;
                    if (ok) {
                        g_created_project = true;
                    }
                }
            } else {
                ok = 1;               /* the separator */
            }
            if (!ok) {
                snprintf(g_status, sizeof g_status, "%.120s", err);
                inval(&g_r.status);
            }
        }
        return true;
    }
    if (control == g_skills_popup && part != 0) {
        if (TrackControl(g_skills_popup, local,
                         (ControlActionUPP)-1L) != 0) {
            int picked = GetControlValue(g_skills_popup) - 2;

            /* Item 1 is the label; rows follow. Choosing one TYPES the
               command into the prompt - the person still sends it, so
               the popup is a shortcut for the slash, not a new path. */
            SetControlValue(g_skills_popup, 1);
            Draw1Control(g_skills_popup);
            if (picked >= 0 && picked < g_skill_count && g_te != NULL) {
                char insert[48];
                long len;

                snprintf(insert, sizeof insert, "%s ",
                         g_skills[picked].command);
                len = (long)strlen(insert);
                if (prompt_size() + len <= kChatPromptMax) {
                    TextFont(g_font);
                    TextSize(9);
                    TEInsert(insert, len, g_te);
                    prompt_grew_or_shrank();
                } else {
                    strcpy(g_status, "The prompt is full");
                    inval(&g_r.status);
                }
            }
        }
        return true;
    }
    if (control == g_sidebar_toggle && part != 0) {
        if (TrackControl(g_sidebar_toggle, local, now_pump_action()) != 0) {
            toggle_sidebar();
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
    row = chat_layout_sidebar_row_at(&g_r, local.h, local.v);
    if (row >= 0) {
        open_chat(g_chat_top + row);
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
        prompt_grew_or_shrank();
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
       the wire came up asks as soon as it is there. Both listings go
       through the one dispatcher — two direct asks in one idle pass
       was one of the stomps it exists to end. */
    if (!g_asked_catalog && conn_phase() == kConnConnected) {
        g_want_catalog = true;
    }
    ask_when_free();
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
        /* Every listed row answers a send - the host lists only what
           it can serve; the loading tail keeps the count honest. */
        snprintf(out, (size_t)cap, "%d model%s from %.24s%s",
                 g_model_count, g_model_count == 1 ? "" : "s",
                 g_models_provider,
                 g_models_loading ? " (more coming)" : "");
        return;
    }
    if (g_models_loading) {
        snprintf(out, (size_t)cap, "Asking %.24s for its models...",
                 g_models_provider);
        return;
    }
    if (g_provider_count > 0) {
        char peer[40];

        conn_peer_label(peer, sizeof peer);
        snprintf(out, (size_t)cap, "%d provider%s on %.24s",
                 g_provider_count, g_provider_count == 1 ? "" : "s", peer);
        return;
    }
    if (g_asked_catalog) {
        char peer[40];

        conn_peer_label(peer, sizeof peer);
        snprintf(out, (size_t)cap, "%.24s offers no chat", peer);
        return;
    }
    snprintf(out, (size_t)cap, "Asking about models...");
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
        chat_status_text,
        chat_describe_scene,
        chat_copy_text
    };

    return &k_ops;
}
