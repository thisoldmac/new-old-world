#ifndef NOW_CONSOLE_MODEL_H
#define NOW_CONSOLE_MODEL_H

/* The Console's memory: scrollback, command history, and the local
   command table. No windows, no controls, no QuickDraw - the Workshop's
   Console page is one consumer, and a test could be another. State is
   static, so history and scrollback survive module switches for the
   whole run. */

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

void console_model_history_add(const char *command);
/* Walks the history: negative delta = older, positive = newer. Returns
   the recalled command, or "" past the newest entry. */
const char *console_model_history_recall(short delta);

/* Appends the first-run banner if the scrollback is empty. */
void console_model_banner(void);

#endif /* NOW_CONSOLE_MODEL_H */
