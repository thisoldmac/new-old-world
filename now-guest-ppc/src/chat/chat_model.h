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
    kChatMaxProviders = 8,            /* the providers answer's maxItems */
    kChatPageRows = 16,               /* one models page, the frame bound */
    kChatMaxModels = 64,              /* accumulated across pages */
    kChatRefMax = 8,                  /* ChatSend.ref maxLength */
    kChatMaxLines = 300,              /* transcript ring */
    kChatCols = 96,                   /* stored bytes per line */
    kChatWrapCols = 88,               /* wrap width for streamed text */
    /* Mirrors the contract's ChatSend.prompt maxLength (the ONE
       statement of the cap lives there): 512 raw bytes escape to at
       most 3072 on the wire plus envelope, inside the 4 KB control
       frame - the exec chunk arithmetic. */
    kChatPromptMax = 512
};

/* Buffers hold the contract's maxLength PLUS the terminator - a
   48-byte model name in a char[48] lost its last byte on metal
   (2026-08-02), which is the whole reason sends now carry a bounded
   REF instead of a name. */
typedef struct {
    char provider[25];                /* selector, sent back verbatim */
    char label[32];                   /* MacRoman, drawn in the popup */
    char state[16];                   /* serving | off | no-access | ... */
    char detail[96];                  /* MacRoman, display only */
} ChatProviderRow;

typedef struct {
    char ref[kChatRefMax + 1];        /* host-minted; never displayed */
    char label[32];                   /* the model's name for humans */
    char detail[96];
} ChatModelRow;

/* The sessions half. A roster row is metadata ONLY - the contract
   forbids transcript text here, and a buffer that could hold some
   would be an invitation to send it. */
enum {
    kChatRosterRows = 12,             /* the roster answer's maxItems */
    kChatHistoryRows = 24,            /* one history page's maxItems */
    kChatMaxChats = 60,               /* accumulated across pages */
    kChatMaxProjects = 24
};

typedef struct {
    char ref[kChatRefMax + 1];        /* host-minted; never displayed */
    char label[32];                   /* the chat's title, MacRoman */
    char origin[8];                   /* "guest" | "host" - where typed */
    char project[kChatRefMax + 1];    /* empty when the chat is loose */
    char detail[48];                  /* "3 turns - 18 Aug", display only */
    Boolean current;                  /* the conversation this link is on */
} ChatRosterRow;

typedef struct {
    char ref[kChatRefMax + 1];
    char label[32];
    char home[8];                     /* "host" | "guest" | empty */
    Boolean current;
} ChatProjectRow;

/* One transcript row as it arrives. `kind` is kChatLine* below: who
   said it is a DRAWING fact, and the page right-aligns a person's
   lines whether they were typed a second or a year ago. */
typedef struct {
    int kind;
    char text[kChatCols];
} ChatHistoryRow;

/* Parsers. A malformed frame reads as failure (-1 / 0), never a crash;
   the wire has already matched type, id and which shape was asked. */
int chat_parse_providers(const char *reply, ChatProviderRow *rows,
                         int max);
/* One models page: returns the row count, sets *more when another page
   follows, and copies the echoed provider so a page that arrives after
   the person switched popups reads as stale, not as content. */
int chat_parse_models(const char *reply, ChatModelRow *rows, int max,
                      int *more, char *provider_out, long provider_cap);
/* One roster page: returns the row count and sets *more when another
   page follows, the models-page shape exactly. */
int chat_parse_roster(const char *reply, ChatRosterRow *rows, int max,
                      int *more);
int chat_parse_projects(const char *reply, ChatProjectRow *rows, int max,
                        int *more);
/* One history page, OLDEST FIRST within the page so it appends in
   reading order; *more means older rows remain further back. */
int chat_parse_history(const char *reply, ChatHistoryRow *rows, int max,
                       int *more);

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
   so the page draws text the moment it arrives.

   Every line remembers WHO SAID IT, because that is a drawing fact:
   the page right-aligns the person's lines, and alignment must survive
   the ring dropping old lines. */
enum {
    kChatLineModel = 0,
    kChatLinePerson = 1,
    kChatLineMarker = 2
};

typedef struct {
    char lines[kChatMaxLines][kChatCols];
    unsigned char kind[kChatMaxLines];
    unsigned char adding_kind;        /* what take_line stamps next */
    int count;
    ChatLineFeed feed;
    Boolean answering;
} ChatTranscript;

void chat_transcript_reset(ChatTranscript *t);
/* Lines visible now, the open tail included while answering. */
int chat_transcript_count(const ChatTranscript *t);
const char *chat_transcript_line(const ChatTranscript *t, int index);
/* kChatLine* for the line; the streaming open tail is the model's. */
int chat_transcript_line_kind(const ChatTranscript *t, int index);
/* A whole entry, wrapped, every line carrying the prefix's indent and
   the given kind. */
void chat_transcript_add(ChatTranscript *t, int kind, const char *prefix,
                         const char *text);
void chat_transcript_begin_answer(ChatTranscript *t);
void chat_transcript_feed(ChatTranscript *t, const char *chunk);
void chat_transcript_end_answer(ChatTranscript *t);

#endif /* NOW_CHAT_MODEL_H */
