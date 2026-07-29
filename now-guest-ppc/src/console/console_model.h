#ifndef NOW_CONSOLE_MODEL_H
#define NOW_CONSOLE_MODEL_H

/* The Console's memory: scrollback and the local command table. No
   windows, no controls, no QuickDraw - the Workshop's Console page is one
   consumer, and a test could be another. State is static, so the
   scrollback survives module switches for the whole run.

   The Up/Down HISTORY is not here. It is now-guest-shared/src/console_history.c,
   one implementation both guests compile, and the page that owns the input
   field owns the instance - console_module.c here, conwin.c on NOW-68K. */

enum {
    kConsoleMaxLines = 200,
    kConsoleMaxCols = 128
};

void console_model_append(const char *text);
void console_model_clear(void);
int console_model_count(void);
const char *console_model_line(int index);

/* Echoes the command into the scrollback, runs it, appends the output.
   Commands are the established local table (help, gestalt, screenshot,
   ls, put, tail, mv, trash, untrash, mkdir, vprobe, ps, census, clear),
   falling through to commands.c. */
void console_model_run(const char *command);

/* --- the exec plane ------------------------------------------------------

   The same dispatch, with its output handed to a caller instead of to the
   scrollback, and with no "> line" echo (the host echoes its own).

   This is what makes the HOST console show what a person standing at this
   Mac would see: not a re-rendering of structured output, but the very
   lines console_model_run would have appended. See the "Exec" section of
   the contract preamble; the short version is that a verb added to this
   file is typeable from an unchanged host binary against an unchanged
   contract, and that stops being true the moment anything other than this
   function is asked to produce console text.

   The 68K guest reaches the same property by a different route - its
   dispatch moved to n68_exec.c, because there it lived inside a WINDOW
   rather than in a model. This guest already had the split, so it needs a
   sink and not a surgery.

   `emit` receives one NUL-terminated line at a time with no terminator:
   this model has always been line-oriented (one string per entry), unlike
   the 68K side's CR-separated blocks.

   Returns 1 if the line was interpreted - INCLUDING a command that ran and
   failed, whose failure is in the emitted text where a human can read it -
   and 0 only if no verb on this Mac matched.

   Not re-entrant, and does not need to be: both faces run on the one
   cooperative thread. The sink is saved and restored regardless. */
typedef void (*ConsoleEmit)(void *ctx, const char *line);

int console_model_exec(const char *line, ConsoleEmit emit, void *ctx);

/* Appends the first-run banner if the scrollback is empty. */
void console_model_banner(void);

#endif /* NOW_CONSOLE_MODEL_H */
