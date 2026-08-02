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

static void test_catalog_fills_rows_whatever_their_state(void)
{
    ChatModelRow rows[kChatMaxModels];
    int n;

    n = chat_parse_catalog(
        "{\"type\":\"chat.catalog\",\"id\":4,\"models\":["
        "{\"model\":\"anthropic/claude-opus-5\",\"label\":\"Claude Opus 5\","
        "\"state\":\"serving\",\"detail\":\"Anthropic\"},"
        "{\"model\":\"ollama\",\"label\":\"Ollama\","
        "\"state\":\"unavailable\",\"detail\":\"Nothing at 11434\"},"
        "{\"model\":\"omlx/qwen\",\"label\":\"qwen\",\"state\":\"serving\"}]}",
        rows, kChatMaxModels);
    assert(n == 3);
    assert(strcmp(rows[0].model, "anthropic/claude-opus-5") == 0);
    assert(strcmp(rows[0].label, "Claude Opus 5") == 0);
    assert(strcmp(rows[1].state, "unavailable") == 0);
    assert(strcmp(rows[2].detail, "") == 0);

    /* Malformed: no models array. */
    assert(chat_parse_catalog("{\"type\":\"chat.catalog\",\"id\":1}",
                              rows, kChatMaxModels) == -1);
    /* Empty catalog is an honest zero, not a failure. */
    assert(chat_parse_catalog(
               "{\"type\":\"chat.catalog\",\"id\":1,\"models\":[]}",
               rows, kChatMaxModels) == 0);
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
    chat_transcript_add(&t, "> ", "what runs here?");
    assert(chat_transcript_count(&t) == 1);
    assert(strcmp(chat_transcript_line(&t, 0), "> what runs here?") == 0);

    chat_transcript_begin_answer(&t);
    chat_transcript_feed(&t, "Looking at the ");
    /* The open tail is visible mid-stream. */
    assert(chat_transcript_count(&t) == 2);
    assert(strcmp(chat_transcript_line(&t, 1), "Looking at the ") == 0);
    chat_transcript_feed(&t, "process table.\nDone.");
    chat_transcript_end_answer(&t);
    assert(chat_transcript_count(&t) == 3);
    assert(strcmp(chat_transcript_line(&t, 1),
                  "Looking at the process table.") == 0);
    assert(strcmp(chat_transcript_line(&t, 2), "Done.") == 0);

    /* A wrapped person entry indents its continuation to the prefix. */
    chat_transcript_reset(&t);
    {
        char long_prompt[300];

        long_prompt[0] = '\0';
        for (i = 0; i < 30; ++i) {
            strcat(long_prompt, "again ");
        }
        chat_transcript_add(&t, "> ", long_prompt);
    }
    assert(chat_transcript_count(&t) >= 2);
    assert(chat_transcript_line(&t, 0)[0] == '>');
    assert(chat_transcript_line(&t, 1)[0] == ' ');

    /* The ring rolls: the newest line survives, the oldest goes. */
    chat_transcript_reset(&t);
    for (i = 0; i < kChatMaxLines + 10; ++i) {
        char line[32];

        sprintf(line, "line %d", i);
        chat_transcript_add(&t, NULL, line);
    }
    assert(chat_transcript_count(&t) == kChatMaxLines);
    {
        char want[32];

        sprintf(want, "line %d", kChatMaxLines + 9);
        assert(strcmp(chat_transcript_line(&t, kChatMaxLines - 1), want)
               == 0);
    }
}

int main(void)
{
    test_catalog_fills_rows_whatever_their_state();
    test_delta_and_status_decode_their_text();
    test_result_reads_ok_code_and_message();
    test_feed_is_chunk_safe_across_word_boundaries();
    test_feed_wraps_at_spaces_and_hard_breaks_long_words();
    test_transcript_streams_and_rolls();
    puts("chat_model_test: all passed");
    return 0;
}
