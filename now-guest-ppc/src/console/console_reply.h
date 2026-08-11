#ifndef NOW_CONSOLE_REPLY_H
#define NOW_CONSOLE_REPLY_H

#include "console_model.h"      /* ConsoleEmit, and nothing Toolbox */

/* Renders one `command.result` as the lines a person reads.
 *
 * WHY THIS FILE EXISTS. `console_model.c`'s fallback used to read exactly
 * one field out of a reply - a top-level "message" - and print
 * "command failed" when it was absent. No PowerPC verb has EVER carried a
 * top-level message on success: every one of them answers
 * `output: {<verb>: [[label, value], ...]}`. So the fallback printed
 * "command failed" for every verb that SUCCEEDED and the verb's own words
 * only when it FAILED, which is the meaning of the path exactly inverted.
 * `putstat` is the one that was reported (2026-08-05); it was never alone,
 * and the eighteen verbs that reach the fallback all read the same way.
 *
 * That is the shape docs/command-parity.md is about, one layer below where
 * it usually bites: the verb is PRESENT on both faces and works on one.
 * Nothing could see it, because the parity gate compares dispatch tables
 * and a table cannot say whether a reply renders.
 *
 * So the renderer is its own file, free of the Toolbox, and
 * tests/console_reply_test.c runs it here on the host over one reply of
 * every shape the guest emits. A renderer with a test is the only kind
 * that can be shown to work without a Macintosh in the room. */

enum {
    kConsoleReplyRows = 0,      /* ok, and its rows were emitted */
    kConsoleReplyRefused = 1,   /* ok:false - the guest's own sentence */
    kConsoleReplyOpaque = 2,    /* ok, but the output is not a row table */
    kConsoleReplyMalformed = 3  /* not a reply this console can read */
};

/* Emits zero or more lines through `emit` and returns which of the four
 * above happened. Every outcome emits at least one line: a reader who
 * typed a verb is owed an answer, and silence is the one thing none of
 * these mean. */
int console_reply_render(const char *json, ConsoleEmit emit, void *ctx);

#endif /* NOW_CONSOLE_REPLY_H */
