#ifndef NOW_CHAT_MODEL_H
#define NOW_CHAT_MODEL_H

/* The Chat page's store and parsers: catalog rows, streamed answer
   text wrapped as it arrives, and the reply-frame readers. Toolbox-free
   on purpose - the parsing half of a module is the half worth testing
   with the host cc (cloud_model.h is the pattern), so nothing here may
   include Carbon.

   Text arrives ALREADY MacRoman-expressible: the host converts before
   sending (contract, hostServesChat). Nothing here transcodes. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef unsigned char Boolean;
#endif

enum {
    kChatMaxModels = 16,              /* the catalog's maxItems */
    kChatMaxLines = 300,              /* transcript ring */
    kChatCols = 96,                   /* stored bytes per line */
    kChatWrapCols = 88,               /* wrap width for streamed text */
    /* Mirrors the contract's ChatSend.prompt maxLength (the ONE
       statement of the cap lives there): 512 raw bytes escape to at
       most 3072 on the wire plus envelope, inside the 4 KB control
       frame - the exec chunk arithmetic. */
    kChatPromptMax = 512
};

typedef struct {
    char model[48];                   /* opaque key, sent back verbatim */
    char label[32];                   /* MacRoman, drawn in the popup */
    char state[16];                   /* serving | off | no-access | ... */
    char detail[96];                  /* MacRoman, display only */
} ChatModelRow;

/* Parsers. A malformed frame reads as failure (-1 / 0), never a crash;
   the wire has already matched type and id. */
int chat_parse_catalog(const char *reply, ChatModelRow *rows, int max);
int chat_parse_delta(const char *reply, char *out, long cap, long *seq);
int chat_parse_status(const char *reply, char *out, long cap);
int chat_parse_result(const char *reply, int *ok,
                      char *code, long code_cap,
                      char *message, long message_cap);

/* --- wrap-at-append line feed -------------------------------------------
   Streamed chunks in, whole wrapped lines out through the sink. Chunk-
   safe: a delta may end mid-word, and the open tail carries into the
   next feed. CR and LF close the line; wrapping prefers the last space
   and hard-breaks a word longer than the width. One implementation for
   both faces - the page's transcript and the console verb's emit. */
typedef void (*ChatLineSink)(void *ctx, const char *line);

typedef struct {
    char open[kChatCols];
    int open_len;
    ChatLineSink sink;
    void *ctx;
} ChatLineFeed;

void chat_feed_reset(ChatLineFeed *feed, ChatLineSink sink, void *ctx);
void chat_feed_text(ChatLineFeed *feed, const char *chunk);
void chat_feed_flush(ChatLineFeed *feed);

/* --- the transcript ------------------------------------------------------
   A flat ring of pre-wrapped lines, the console's shape: no variable-
   height rows anywhere in this application, and none here. The person's
   turns carry a "> " prefix, markers "* ", the model's text none. While
   an answer streams, the feed's open tail is visible as one extra line
   so the page draws text the moment it arrives. */
typedef struct {
    char lines[kChatMaxLines][kChatCols];
    int count;
    ChatLineFeed feed;
    Boolean answering;
} ChatTranscript;

void chat_transcript_reset(ChatTranscript *t);
/* Lines visible now, the open tail included while answering. */
int chat_transcript_count(const ChatTranscript *t);
const char *chat_transcript_line(const ChatTranscript *t, int index);
/* A whole entry, wrapped, every line carrying the prefix's indent. */
void chat_transcript_add(ChatTranscript *t, const char *prefix,
                         const char *text);
void chat_transcript_begin_answer(ChatTranscript *t);
void chat_transcript_feed(ChatTranscript *t, const char *chunk);
void chat_transcript_end_answer(ChatTranscript *t);

#endif /* NOW_CHAT_MODEL_H */
