#include "chat_model.h"

#include <string.h>

#include "../core/json.h"

/* Parsers first, feed and transcript below. Everything is bounded
   writes into caller storage; a malformed frame reads as failure and
   leaves the outputs unclaimed. */

int chat_parse_providers(const char *reply, ChatProviderRow *rows,
                         int max)
{
    const char *p;
    char object[512];
    int count = 0;

    if (reply == NULL || rows == NULL || max <= 0) {
        return -1;
    }
    p = now_json_array(reply, "providers");
    if (p == NULL) {
        return -1;
    }
    while (count < max
           && (p = now_json_next_object(p, object, sizeof object)) != NULL) {
        ChatProviderRow *row = &rows[count];

        memset(row, 0, sizeof *row);
        if (!now_json_find_text(object, "provider", row->provider,
                                sizeof row->provider)) {
            continue;                 /* a row without its selector is no row */
        }
        if (!now_json_find_text(object, "label", row->label,
                                sizeof row->label)) {
            strncpy(row->label, row->provider, sizeof row->label - 1);
        }
        if (!now_json_find_string(object, "tools", row->tools,
                                  sizeof row->tools)) {
            strcpy(row->tools, "full");
        }
        if (!now_json_find_string(object, "state", row->state,
                                  sizeof row->state)) {
            strcpy(row->state, "serving");
        }
        now_json_find_text(object, "detail", row->detail,
                           sizeof row->detail);
        ++count;
    }
    return count;
}

int chat_parse_models(const char *reply, ChatModelRow *rows, int max,
                      int *more, char *provider_out, long provider_cap)
{
    const char *p;
    char object[512];
    int count = 0;

    if (more != NULL) {
        *more = 0;
    }
    if (provider_out != NULL && provider_cap > 0) {
        provider_out[0] = '\0';
    }
    if (reply == NULL || rows == NULL || max <= 0) {
        return -1;
    }
    p = now_json_array(reply, "models");
    if (p == NULL) {
        return -1;
    }
    if (more != NULL) {
        *more = now_json_find_bool(reply, "more", 0) == 1;
    }
    if (provider_out != NULL && provider_cap > 0) {
        now_json_find_text(reply, "provider", provider_out, provider_cap);
    }
    while (count < max
           && (p = now_json_next_object(p, object, sizeof object)) != NULL) {
        ChatModelRow *row = &rows[count];

        memset(row, 0, sizeof *row);
        if (!now_json_find_string(object, "ref", row->ref,
                                  sizeof row->ref)) {
            continue;                 /* a row without its ref is no row */
        }
        if (!now_json_find_text(object, "label", row->label,
                                sizeof row->label)) {
            strncpy(row->label, row->ref, sizeof row->label - 1);
        }
        now_json_find_text(object, "detail", row->detail,
                           sizeof row->detail);
        ++count;
    }
    return count;
}

int chat_parse_roster(const char *reply, ChatRosterRow *rows, int max,
                      int *more)
{
    const char *p;
    char object[512];
    int count = 0;

    if (more != NULL) {
        *more = 0;
    }
    if (reply == NULL || rows == NULL || max <= 0) {
        return -1;
    }
    p = now_json_array(reply, "chats");
    if (p == NULL) {
        return -1;
    }
    if (more != NULL) {
        *more = now_json_find_bool(reply, "more", 0) == 1;
    }
    while (count < max
           && (p = now_json_next_object(p, object, sizeof object)) != NULL) {
        ChatRosterRow *row = &rows[count];

        memset(row, 0, sizeof *row);
        if (!now_json_find_string(object, "ref", row->ref,
                                  sizeof row->ref)) {
            continue;                 /* a row without its ref is no row */
        }
        if (!now_json_find_text(object, "label", row->label,
                                sizeof row->label)) {
            strncpy(row->label, row->ref, sizeof row->label - 1);
        }
        /* Absent origin reads as the OTHER machine, never as this one:
           a chat this guest did not type is the one a person needs
           warning about, so silence must not claim local authorship. */
        if (!now_json_find_string(object, "origin", row->origin,
                                  sizeof row->origin)) {
            strcpy(row->origin, "host");
        }
        now_json_find_string(object, "project", row->project,
                             sizeof row->project);
        now_json_find_text(object, "detail", row->detail,
                           sizeof row->detail);
        row->current = now_json_find_bool(object, "current", 0) == 1;
        ++count;
    }
    return count;
}

int chat_parse_projects(const char *reply, ChatProjectRow *rows, int max,
                        int *more)
{
    const char *p;
    char object[512];
    int count = 0;

    if (more != NULL) {
        *more = 0;
    }
    if (reply == NULL || rows == NULL || max <= 0) {
        return -1;
    }
    p = now_json_array(reply, "projects");
    if (p == NULL) {
        return -1;
    }
    if (more != NULL) {
        *more = now_json_find_bool(reply, "more", 0) == 1;
    }
    while (count < max
           && (p = now_json_next_object(p, object, sizeof object)) != NULL) {
        ChatProjectRow *row = &rows[count];

        memset(row, 0, sizeof *row);
        if (!now_json_find_string(object, "ref", row->ref,
                                  sizeof row->ref)) {
            continue;
        }
        if (!now_json_find_text(object, "label", row->label,
                                sizeof row->label)) {
            strncpy(row->label, row->ref, sizeof row->label - 1);
        }
        now_json_find_string(object, "home", row->home, sizeof row->home);
        row->current = now_json_find_bool(object, "current", 0) == 1;
        ++count;
    }
    return count;
}

int chat_parse_skills(const char *reply, ChatSkillRow *rows, int max,
                      int *more)
{
    const char *p;
    char object[512];
    int count = 0;

    if (more != NULL) {
        *more = 0;
    }
    if (reply == NULL || rows == NULL || max <= 0) {
        return -1;
    }
    p = now_json_array(reply, "skills");
    if (p == NULL) {
        return -1;
    }
    if (more != NULL) {
        *more = now_json_find_bool(reply, "more", 0) == 1;
    }
    while (count < max
           && (p = now_json_next_object(p, object, sizeof object)) != NULL) {
        ChatSkillRow *row = &rows[count];

        memset(row, 0, sizeof *row);
        if (!now_json_find_text(object, "command", row->command,
                                sizeof row->command)) {
            continue;
        }
        now_json_find_text(object, "detail", row->detail,
                           sizeof row->detail);
        ++count;
    }
    return count;
}

int chat_parse_history(const char *reply, ChatHistoryRow *rows, int max,
                       int *more)
{
    const char *p;
    char object[kChatCols + 128];
    char kind[12];
    int count = 0;

    if (more != NULL) {
        *more = 0;
    }
    if (reply == NULL || rows == NULL || max <= 0) {
        return -1;
    }
    p = now_json_array(reply, "rows");
    if (p == NULL) {
        return -1;
    }
    if (more != NULL) {
        *more = now_json_find_bool(reply, "more", 0) == 1;
    }
    while (count < max
           && (p = now_json_next_object(p, object, sizeof object)) != NULL) {
        ChatHistoryRow *row = &rows[count];

        memset(row, 0, sizeof *row);
        if (!now_json_find_text(object, "text", row->text,
                                sizeof row->text)) {
            continue;
        }
        /* Anything but "person" draws as the model said it. A row whose
           kind this build has never heard of is still CONTENT - dropping
           it would put a hole in a transcript, and drawing it as the
           person's would put words in their mouth. */
        if (now_json_find_string(object, "kind", kind, sizeof kind)
            && strcmp(kind, "person") == 0) {
            row->kind = kChatLinePerson;
        } else if (strcmp(kind, "tool") == 0 || strcmp(kind, "note") == 0) {
            row->kind = kChatLineMarker;
        } else {
            row->kind = kChatLineModel;
        }
        ++count;
    }
    return count;
}

int chat_parse_delta(const char *reply, char *out, long cap, long *seq)
{
    if (reply == NULL || out == NULL || cap <= 0) {
        return 0;
    }
    if (seq != NULL) {
        *seq = now_json_find_int(reply, "seq", -1);
    }
    return now_json_find_text(reply, "text", out, cap);
}

int chat_parse_status(const char *reply, char *out, long cap)
{
    if (reply == NULL || out == NULL || cap <= 0) {
        return 0;
    }
    /* An absent text is a malformed status; an EMPTY one is a real
       answer that clears the line, and find_text reports it as found. */
    return now_json_find_text(reply, "text", out, cap);
}

int chat_parse_result(const char *reply, int *ok,
                      char *code, long code_cap,
                      char *message, long message_cap)
{
    int parsed_ok;

    if (reply == NULL || ok == NULL) {
        return 0;
    }
    parsed_ok = now_json_find_bool(reply, "ok", -1);
    if (parsed_ok < 0) {
        return 0;
    }
    *ok = parsed_ok;
    if (code != NULL && code_cap > 0) {
        code[0] = '\0';
        now_json_find_string(reply, "code", code, code_cap);
    }
    if (message != NULL && message_cap > 0) {
        message[0] = '\0';
        now_json_find_text(reply, "message", message, message_cap);
    }
    return 1;
}


/* --- the line feed ------------------------------------------------------ */

void chat_feed_reset(ChatLineFeed *feed, ChatLineSink sink, void *ctx)
{
    feed->open[0] = '\0';
    feed->open_len = 0;
    feed->sink = sink;
    feed->ctx = ctx;
}

static void feed_emit(ChatLineFeed *feed)
{
    feed->open[feed->open_len] = '\0';
    if (feed->sink != NULL) {
        feed->sink(feed->ctx, feed->open);
    }
    feed->open_len = 0;
    feed->open[0] = '\0';
}

/* Close the open line at its best break: the last space when there is
   one, else the full width (a word longer than the line hard-breaks,
   which is what a terminal would do too). */
static void feed_wrap(ChatLineFeed *feed)
{
    int break_at = -1;
    int i;

    for (i = feed->open_len - 1; i > 0; --i) {
        if (feed->open[i] == ' ') {
            break_at = i;
            break;
        }
    }
    if (break_at <= 0) {
        feed_emit(feed);
        return;
    }
    {
        char tail[kChatCols];
        int tail_len = feed->open_len - break_at - 1;

        memcpy(tail, feed->open + break_at + 1, (size_t)tail_len);
        feed->open_len = break_at;
        feed_emit(feed);
        memcpy(feed->open, tail, (size_t)tail_len);
        feed->open_len = tail_len;
        feed->open[tail_len] = '\0';
    }
}

void chat_feed_text(ChatLineFeed *feed, const char *chunk)
{
    const char *p;

    if (chunk == NULL) {
        return;
    }
    for (p = chunk; *p != '\0'; ++p) {
        if (*p == '\r' || *p == '\n') {
            feed_emit(feed);
            continue;
        }
        feed->open[feed->open_len++] = *p;
        feed->open[feed->open_len] = '\0';
        if (feed->open_len >= kChatWrapCols) {
            feed_wrap(feed);
        }
    }
}

void chat_feed_flush(ChatLineFeed *feed)
{
    if (feed->open_len > 0) {
        feed_emit(feed);
    }
}

/* --- the transcript ----------------------------------------------------- */

/* One line has just left the top of the ring, so every surviving row
   answers to an index one lower. The selection follows them down. */
static void selection_rolled(ChatTranscript *t)
{
    if (t->sel_anchor < 0) {
        return;
    }
    --t->sel_anchor;
    --t->sel_extent;
    if (t->sel_anchor < 0 && t->sel_extent < 0) {
        t->sel_anchor = -1;           /* every row it named is gone */
        t->sel_extent = -1;
        return;
    }
    if (t->sel_anchor < 0) {
        t->sel_anchor = 0;            /* the top row fell off; the rest hold */
    }
    if (t->sel_extent < 0) {
        t->sel_extent = 0;
    }
}

static void transcript_take_line(void *ctx, const char *line)
{
    ChatTranscript *t = (ChatTranscript *)ctx;

    if (t->count == kChatMaxLines) {
        memmove(t->lines[0], t->lines[1],
                (size_t)(kChatMaxLines - 1) * kChatCols);
        memmove(t->kind, t->kind + 1, (size_t)(kChatMaxLines - 1));
        --t->count;
        selection_rolled(t);
    }
    strncpy(t->lines[t->count], line, kChatCols - 1);
    t->lines[t->count][kChatCols - 1] = '\0';
    t->kind[t->count] = t->adding_kind;
    ++t->count;
}

void chat_transcript_reset(ChatTranscript *t)
{
    t->count = 0;
    t->answering = 0;
    t->adding_kind = kChatLineModel;
    t->sel_anchor = -1;
    t->sel_extent = -1;
    chat_feed_reset(&t->feed, transcript_take_line, t);
}

void chat_transcript_select(ChatTranscript *t, int anchor, int extent)
{
    int last = chat_transcript_count(t) - 1;

    if (anchor < 0 || extent < 0 || last < 0) {
        chat_transcript_clear_selection(t);
        return;
    }
    if (anchor > last) {
        anchor = last;
    }
    if (extent > last) {
        extent = last;
    }
    t->sel_anchor = anchor;
    t->sel_extent = extent;
}

void chat_transcript_clear_selection(ChatTranscript *t)
{
    t->sel_anchor = -1;
    t->sel_extent = -1;
}

int chat_transcript_sel_anchor(const ChatTranscript *t)
{
    return t->sel_anchor;
}

int chat_transcript_sel_extent(const ChatTranscript *t)
{
    return t->sel_extent;
}

int chat_transcript_count(const ChatTranscript *t)
{
    /* The open tail is one visible line while an answer streams, so
       text appears the moment it arrives rather than at the next wrap. */
    if (t->answering && t->feed.open_len > 0) {
        return t->count + 1;
    }
    return t->count;
}

const char *chat_transcript_line(const ChatTranscript *t, int index)
{
    if (index < 0 || index >= chat_transcript_count(t)) {
        return "";
    }
    if (index == t->count) {
        return t->feed.open;
    }
    return t->lines[index];
}

int chat_transcript_line_kind(const ChatTranscript *t, int index)
{
    if (index < 0 || index >= chat_transcript_count(t)
        || index == t->count) {       /* the open tail is the model's */
        return kChatLineModel;
    }
    return t->kind[index];
}

/* The adapter for chat_transcript_add: the prefix on the first line,
   the same width of spaces on continuations, so a wrapped entry still
   reads as one. */
typedef struct {
    ChatTranscript *transcript;
    const char *prefix;
    size_t prefix_len;
    int first;
} PrefixedSink;

static void prefixed_take_line(void *ctx, const char *text)
{
    PrefixedSink *state = (PrefixedSink *)ctx;
    char line[kChatCols];
    size_t i;

    line[0] = '\0';
    if (state->prefix_len > 0 && state->prefix_len < sizeof line - 1) {
        if (state->first) {
            strcpy(line, state->prefix);
        } else {
            for (i = 0; i < state->prefix_len; ++i) {
                line[i] = ' ';
            }
            line[state->prefix_len] = '\0';
        }
    }
    strncat(line, text, sizeof line - strlen(line) - 1);
    transcript_take_line(state->transcript, line);
    state->first = 0;
}

void chat_transcript_add(ChatTranscript *t, int kind, const char *prefix,
                         const char *text)
{
    /* A whole entry through its own feed, so wrapping is the one
       implementation. */
    ChatLineFeed feed;
    PrefixedSink state;

    state.transcript = t;
    state.prefix = prefix;
    state.prefix_len = prefix != NULL ? strlen(prefix) : 0;
    state.first = 1;
    t->adding_kind = (unsigned char)kind;
    chat_feed_reset(&feed, prefixed_take_line, &state);
    chat_feed_text(&feed, text != NULL ? text : "");
    chat_feed_flush(&feed);
    if (state.first) {
        /* Nothing was emitted - an empty entry still occupies a line;
           a blank prompt is a thing a person can send and should see. */
        prefixed_take_line(&state, "");
    }
    /* Streamed lines landing later are the model's. */
    t->adding_kind = kChatLineModel;
}

void chat_transcript_begin_answer(ChatTranscript *t)
{
    chat_feed_flush(&t->feed);
    t->answering = 1;
}

void chat_transcript_feed(ChatTranscript *t, const char *chunk)
{
    chat_feed_text(&t->feed, chunk);
}

void chat_transcript_end_answer(ChatTranscript *t)
{
    chat_feed_flush(&t->feed);
    t->answering = 0;
}
