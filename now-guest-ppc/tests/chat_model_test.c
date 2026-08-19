/* The Chat page's parsers and transcript, run where a debugger exists:
     cc -Wall -Wextra -Werror -I ../src -I ../src/core -I ../src/chat \
        chat_model_test.c ../src/chat/chat_model.c ../src/core/json.c \
        -o /tmp/t && /tmp/t
   Worth proving off-metal: the catalog fills the popup whatever the
   states are, delta text survives escapes, results read their code,
   and the wrap-at-append transcript is chunk-safe - a delta ending
   mid-word continues into the next without a seam, CR and LF close
   lines, and the ring rolls without losing the newest text. */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "chat_model.h"

static void test_providers_fill_rows_whatever_their_state(void)
{
    ChatProviderRow rows[kChatMaxProviders];
    int n;

    n = chat_parse_providers(
        "{\"type\":\"chat.catalog\",\"id\":4,\"providers\":["
        "{\"provider\":\"anthropic\",\"label\":\"Anthropic\","
        "\"state\":\"serving\",\"detail\":\"Signed in\"},"
        "{\"provider\":\"ollama\",\"label\":\"Ollama\","
        "\"state\":\"unavailable\",\"detail\":\"Nothing at 11434\"},"
        "{\"provider\":\"omlx\",\"label\":\"oMLX\",\"state\":\"serving\"}]}",
        rows, kChatMaxProviders);
    assert(n == 3);
    assert(strcmp(rows[0].provider, "anthropic") == 0);
    assert(strcmp(rows[0].label, "Anthropic") == 0);
    assert(strcmp(rows[1].state, "unavailable") == 0);
    assert(strcmp(rows[1].detail, "Nothing at 11434") == 0);
    assert(strcmp(rows[2].detail, "") == 0);

    /* Malformed: no providers array. */
    assert(chat_parse_providers("{\"type\":\"chat.catalog\",\"id\":1}",
                                rows, kChatMaxProviders) == -1);
    /* Empty is an honest zero, not a failure. */
    assert(chat_parse_providers(
               "{\"type\":\"chat.catalog\",\"id\":1,\"providers\":[]}",
               rows, kChatMaxProviders) == 0);
}

static void test_model_pages_carry_refs_and_more(void)
{
    ChatModelRow rows[kChatPageRows];
    char from[25];
    int more = -1;
    int n;

    n = chat_parse_models(
        "{\"type\":\"chat.catalog\",\"id\":5,\"provider\":\"omlx\","
        "\"models\":["
        "{\"ref\":\"m1\",\"label\":\"Qwen3.5-122B-A10B-Heretic\"},"
        "{\"ref\":\"m2\",\"label\":\"qwen3-coder\",\"detail\":\"local\"}],"
        "\"more\":true}",
        rows, kChatPageRows, &more, from, sizeof from);
    assert(n == 2);
    assert(more == 1);
    assert(strcmp(from, "omlx") == 0);
    assert(strcmp(rows[0].ref, "m1") == 0);
    assert(strcmp(rows[0].label, "Qwen3.5-122B-A10B-Heretic") == 0);
    assert(strcmp(rows[1].detail, "local") == 0);

    /* The last page: more false (or absent) ends the loop. */
    n = chat_parse_models(
        "{\"type\":\"chat.catalog\",\"id\":6,\"provider\":\"omlx\","
        "\"models\":[{\"ref\":\"m3\",\"label\":\"llama\"}],\"more\":false}",
        rows, kChatPageRows, &more, from, sizeof from);
    assert(n == 1 && more == 0);
    n = chat_parse_models(
        "{\"type\":\"chat.catalog\",\"id\":7,\"provider\":\"x\","
        "\"models\":[]}",
        rows, kChatPageRows, &more, from, sizeof from);
    assert(n == 0 && more == 0 && strcmp(from, "x") == 0);

    /* Malformed: no models array. */
    assert(chat_parse_models("{\"type\":\"chat.catalog\",\"id\":1}",
                             rows, kChatPageRows, &more, from,
                             sizeof from) == -1);
}

static void test_delta_and_status_decode_their_text(void)
{
    char text[256];
    long seq = -2;

    assert(chat_parse_delta(
               "{\"type\":\"chat.delta\",\"id\":9,\"seq\":3,"
               "\"text\":\"a \\\"quoted\\\" piece\\nnext\"}",
               text, sizeof text, &seq));
    assert(seq == 3);
    /* \n decodes to CR - Mac line endings, decode_body's rule. */
    assert(strcmp(text, "a \"quoted\" piece\rnext") == 0);

    /* A status with empty text is FOUND - it clears the line. */
    assert(chat_parse_status(
               "{\"type\":\"chat.status\",\"id\":9,\"text\":\"\"}",
               text, sizeof text));
    assert(text[0] == '\0');
    /* One with no text field at all is malformed. */
    assert(!chat_parse_status("{\"type\":\"chat.status\",\"id\":9}",
                              text, sizeof text));
}

static void test_result_reads_ok_code_and_message(void)
{
    int ok = -1;
    char code[24];
    char message[96];

    assert(chat_parse_result(
               "{\"type\":\"chat.result\",\"id\":9,\"ok\":false,"
               "\"code\":\"busy\",\"message\":\"An answer is arriving\"}",
               &ok, code, sizeof code, message, sizeof message));
    assert(ok == 0);
    assert(strcmp(code, "busy") == 0);
    assert(strcmp(message, "An answer is arriving") == 0);

    assert(chat_parse_result(
               "{\"type\":\"chat.result\",\"id\":10,\"ok\":true}",
               &ok, code, sizeof code, message, sizeof message));
    assert(ok == 1);
    assert(code[0] == '\0');

    /* No ok field: malformed, outputs unclaimed. */
    assert(!chat_parse_result("{\"type\":\"chat.result\",\"id\":1}",
                              &ok, code, sizeof code,
                              message, sizeof message));
}

/* --- the feed ----------------------------------------------------------- */

static char g_sunk[16][kChatCols];
static int g_sunk_count;

static void sink(void *ctx, const char *line)
{
    (void)ctx;
    strncpy(g_sunk[g_sunk_count], line, kChatCols - 1);
    ++g_sunk_count;
}

static void test_feed_is_chunk_safe_across_word_boundaries(void)
{
    ChatLineFeed feed;

    g_sunk_count = 0;
    chat_feed_reset(&feed, sink, NULL);
    /* One sentence split mid-word across three deltas. */
    chat_feed_text(&feed, "The quick brown fo");
    chat_feed_text(&feed, "x jumps over");
    chat_feed_text(&feed, " the lazy dog.\n");
    assert(g_sunk_count == 1);
    assert(strcmp(g_sunk[0], "The quick brown fox jumps over the lazy dog.")
           == 0);
}

static void test_feed_wraps_at_spaces_and_hard_breaks_long_words(void)
{
    ChatLineFeed feed;
    char long_text[400];
    int i;

    g_sunk_count = 0;
    chat_feed_reset(&feed, sink, NULL);
    /* 20 x "word " = 100 chars: must wrap at a space before 88. */
    long_text[0] = '\0';
    for (i = 0; i < 20; ++i) {
        strcat(long_text, "word ");
    }
    chat_feed_text(&feed, long_text);
    chat_feed_flush(&feed);
    assert(g_sunk_count == 2);
    assert(strlen(g_sunk[0]) <= kChatWrapCols);
    assert(g_sunk[0][strlen(g_sunk[0]) - 1] != ' ');

    /* A single word longer than the width hard-breaks. */
    g_sunk_count = 0;
    chat_feed_reset(&feed, sink, NULL);
    for (i = 0; i < 120; ++i) {
        chat_feed_text(&feed, "x");
    }
    chat_feed_flush(&feed);
    assert(g_sunk_count == 2);
    assert(strlen(g_sunk[0]) == kChatWrapCols);
}

static void test_transcript_streams_and_rolls(void)
{
    static ChatTranscript t;
    int i;

    chat_transcript_reset(&t);
    chat_transcript_add(&t, kChatLinePerson, "> ", "what runs here?");
    assert(chat_transcript_count(&t) == 1);
    assert(strcmp(chat_transcript_line(&t, 0), "> what runs here?") == 0);
    assert(chat_transcript_line_kind(&t, 0) == kChatLinePerson);

    chat_transcript_begin_answer(&t);
    chat_transcript_feed(&t, "Looking at the ");
    /* The open tail is visible mid-stream, and it is the model's. */
    assert(chat_transcript_count(&t) == 2);
    assert(strcmp(chat_transcript_line(&t, 1), "Looking at the ") == 0);
    assert(chat_transcript_line_kind(&t, 1) == kChatLineModel);
    chat_transcript_feed(&t, "process table.\nDone.");
    chat_transcript_end_answer(&t);
    assert(chat_transcript_count(&t) == 3);
    assert(strcmp(chat_transcript_line(&t, 1),
                  "Looking at the process table.") == 0);
    assert(strcmp(chat_transcript_line(&t, 2), "Done.") == 0);
    assert(chat_transcript_line_kind(&t, 1) == kChatLineModel);
    assert(chat_transcript_line_kind(&t, 2) == kChatLineModel);

    /* A wrapped person entry indents its continuation to the prefix,
       and EVERY wrapped line keeps the person's kind - alignment must
       not fall off at the wrap. */
    chat_transcript_reset(&t);
    {
        char long_prompt[300];

        long_prompt[0] = '\0';
        for (i = 0; i < 30; ++i) {
            strcat(long_prompt, "again ");
        }
        chat_transcript_add(&t, kChatLinePerson, "> ", long_prompt);
    }
    assert(chat_transcript_count(&t) >= 2);
    assert(chat_transcript_line(&t, 0)[0] == '>');
    assert(chat_transcript_line(&t, 1)[0] == ' ');
    assert(chat_transcript_line_kind(&t, 0) == kChatLinePerson);
    assert(chat_transcript_line_kind(&t, 1) == kChatLinePerson);

    /* A marker is its own kind. */
    chat_transcript_add(&t, kChatLineMarker, "* ", "cancelled");
    assert(chat_transcript_line_kind(&t, chat_transcript_count(&t) - 1)
           == kChatLineMarker);

    /* The ring rolls: the newest line survives, the oldest goes - and
       the kinds roll WITH their lines. */
    chat_transcript_reset(&t);
    chat_transcript_add(&t, kChatLinePerson, "> ", "first");
    for (i = 0; i < kChatMaxLines + 10; ++i) {
        char line[32];

        snprintf(line, sizeof line, "line %d", i);
        chat_transcript_add(&t, kChatLineModel, NULL, line);
    }
    assert(chat_transcript_count(&t) == kChatMaxLines);
    {
        char want[32];

        snprintf(want, sizeof want, "line %d", kChatMaxLines + 9);
        assert(strcmp(chat_transcript_line(&t, kChatMaxLines - 1), want)
               == 0);
    }
    /* The person's line rolled out; nothing left claims their kind. */
    for (i = 0; i < chat_transcript_count(&t); ++i) {
        assert(chat_transcript_line_kind(&t, i) == kChatLineModel);
    }
}

/* The sessions half. Frames are written the way the host writes them,
   which is the one thing a parser test must not invent - these are the
   shapes ChatServingTests asserts on the other side. */

static void test_roster_rows_carry_origin_and_never_transcript_text(void)
{
    const char *reply =
        "{\"type\":\"chat.roster\",\"id\":7,\"chats\":["
        "{\"ref\":\"c1\",\"label\":\"hello from the classic Mac\","
        "\"origin\":\"guest\",\"detail\":\"3 turns - 18 Aug\","
        "\"current\":true},"
        "{\"ref\":\"c2\",\"label\":\"typed upstairs\","
        "\"origin\":\"host\",\"project\":\"p3\"}"
        "],\"more\":true}";
    ChatRosterRow rows[kChatRosterRows];
    int more = 0;
    int n = chat_parse_roster(reply, rows, kChatRosterRows, &more);

    assert(n == 2);
    assert(more == 1);
    assert(strcmp(rows[0].ref, "c1") == 0);
    assert(strcmp(rows[0].origin, "guest") == 0);
    assert(rows[0].current);
    assert(rows[0].project[0] == '\0');
    assert(strcmp(rows[1].origin, "host") == 0);
    assert(strcmp(rows[1].project, "p3") == 0);
    assert(!rows[1].current);
}

/* Silence about origin must not claim this machine typed it: the chat
   a person needs warning about is the one they wrote somewhere else. */
static void test_a_row_with_no_origin_is_not_claimed_as_local(void)
{
    const char *reply =
        "{\"type\":\"chat.roster\",\"id\":1,\"chats\":["
        "{\"ref\":\"c1\",\"label\":\"older than the field\"}"
        "],\"more\":false}";
    ChatRosterRow rows[2];

    assert(chat_parse_roster(reply, rows, 2, NULL) == 1);
    assert(strcmp(rows[0].origin, "host") == 0);
}

static void test_projects_carry_their_home(void)
{
    const char *reply =
        "{\"type\":\"chat.projectroster\",\"id\":9,\"projects\":["
        "{\"ref\":\"p1\",\"label\":\"Beeper\",\"home\":\"guest\","
        "\"current\":true},"
        "{\"ref\":\"p2\",\"label\":\"Notes\",\"home\":\"host\"}"
        "],\"more\":false}";
    ChatProjectRow rows[kChatMaxProjects];
    int more = 1;
    int n = chat_parse_projects(reply, rows, kChatMaxProjects, &more);

    assert(n == 2);
    assert(more == 0);
    assert(strcmp(rows[0].home, "guest") == 0);
    assert(rows[0].current);
    assert(strcmp(rows[1].home, "host") == 0);
}

static void test_history_keeps_who_said_it(void)
{
    const char *reply =
        "{\"type\":\"chat.transcript\",\"id\":3,\"rows\":["
        "{\"kind\":\"person\",\"text\":\"what is running?\"},"
        "{\"kind\":\"tool\",\"text\":\"now_list_processes\"},"
        "{\"kind\":\"model\",\"text\":\"Finder and NOW.\"},"
        "{\"kind\":\"seance\",\"text\":\"from a later build\"}"
        "],\"more\":true}";
    ChatHistoryRow rows[kChatHistoryRows];
    int more = 0;
    int n = chat_parse_history(reply, rows, kChatHistoryRows, &more);

    assert(n == 4);
    assert(more == 1);
    assert(rows[0].kind == kChatLinePerson);
    assert(strcmp(rows[0].text, "what is running?") == 0);
    assert(rows[1].kind == kChatLineMarker);
    assert(rows[2].kind == kChatLineModel);
    /* A kind from a later build is CONTENT: dropping it holes the
       transcript, and drawing it as the person's puts words in their
       mouth. */
    assert(rows[3].kind == kChatLineModel);
}

static void test_a_malformed_page_reads_as_failure(void)
{
    ChatRosterRow rows[2];
    ChatHistoryRow history[2];

    assert(chat_parse_roster("{\"type\":\"chat.roster\"}", rows, 2, NULL)
           == -1);
    assert(chat_parse_history("{}", history, 2, NULL) == -1);
    assert(chat_parse_roster(NULL, rows, 2, NULL) == -1);
}

int main(void)
{
    test_providers_fill_rows_whatever_their_state();
    test_model_pages_carry_refs_and_more();
    test_delta_and_status_decode_their_text();
    test_result_reads_ok_code_and_message();
    test_feed_is_chunk_safe_across_word_boundaries();
    test_feed_wraps_at_spaces_and_hard_breaks_long_words();
    test_transcript_streams_and_rolls();
    test_roster_rows_carry_origin_and_never_transcript_text();
    test_a_row_with_no_origin_is_not_claimed_as_local();
    test_projects_carry_their_home();
    test_history_keeps_who_said_it();
    test_a_malformed_page_reads_as_failure();
    puts("chat_model_test: all passed");
    return 0;
}
