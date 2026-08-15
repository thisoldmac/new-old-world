#ifndef NOW_LOGQUERY_H
#define NOW_LOGQUERY_H

/* Selecting lines out of the log ring, for BOTH faces of `tail`.
   ------------------------------------------------------------------
   The wire (`run_tail` in commands.c) and the console (`console_model.c`)
   ask the same three questions — how many, which area, older than what —
   and per docs/command-parity.md rule 2 the answer must be computed once.
   This is that once. The faces render; nothing here formats.

   Deliberately Toolbox-free, like qdtrace_json.c: the native test
   (`logquery_native_test.c`, scripts/test-native) compiles this file with
   the host `cc` and supplies its own ring, so paging and filtering are
   proved without an emulator. It therefore declares the three ring
   accessors it reads instead of including nowlog.h (which needs Carbon);
   the declarations must match nowlog.h exactly, and the compiler holds
   them to it in every guest build, where both headers meet. */

/* One page is at most 40 lines: the contract's own bound for `tail`
   ("most 40 per answer"), sized so a full page of short lines fits a
   4 KB control frame. The area tag field is 6 wide because nowlog.c
   writes it "%-6.6s". Stated here, read by both faces. */
enum { kLogQueryPageMax = 40, kLogQueryAreaMax = 6 };

/* Provided by nowlog.c in the application, by the harness in the native
   test. Kept identical to nowlog.h's declarations. */
int now_log_count(void);
const char *now_log_line(int index);
unsigned long now_log_seq(void);

typedef struct {
    long lines;                        /* wanted per page; clamped 1..40 */
    char area[kLogQueryAreaMax + 2];   /* "" = every area */
    unsigned long before;              /* only seq < before; 0 = newest */
} LogQuery;

typedef struct {
    int idx[kLogQueryPageMax];          /* ring indexes, OLDEST first */
    unsigned long seq[kLogQueryPageMax];/* their sequence numbers */
    int returned;                       /* how many of idx/seq are set */
    long matching;                      /* held lines matching the area */
    long older;                         /* matching, seq < before, not taken:
                                           what the next page would serve */
} LogPage;

/* The contract's defaults: 20 lines, every area, newest first. */
void now_logquery_defaults(LogQuery *q);

/* The x-line grammar, shared by the console and the wire's line form:
   "tail [lines] [area] [before N]". The first bare integer is the count,
   a bare word is an area tag (truncated to the field's 6), the integer
   after the word "before" is the cursor; anything else is ignored, which
   is the lenience the old one-integer grammar promised. */
void now_logquery_parse_line(const char *line, LogQuery *q);

/* Does a stored ring line ("HH:MM:SS area message") belong to `tag`?
   An empty tag matches everything; otherwise the tag must equal the
   6-wide area field with its padding ignored — exact match, never a
   prefix, so "app" does not quietly read another area's lines. */
int now_logquery_area_matches(const char *stored, const char *tag);

/* Walk the ring newest-to-oldest and fill one page. Sequence numbers
   count from 1 at launch and never renumber, so a cursor stays honest
   over a live ring: appended lines change nothing already numbered, and
   rolled-off lines are simply no longer served. */
void now_logquery_select(const LogQuery *q, LogPage *page);

#endif /* NOW_LOGQUERY_H */
