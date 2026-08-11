/*
 * console_history.h - the up/down-arrow command history for a guest
 * console, ONE implementation compiled by BOTH guests.
 *
 * WHY THIS FILE IS NOT IN EITHER GUEST'S TREE.
 *
 * "Which line should the input field show now" is decidable without a
 * TERec, a WindowRef, a Carbon event or a WaitNextEvent - so it is
 * decided here and tested on the host
 * (now-guest-shared/tests/console_history_test.c). Neither guest's console
 * had a Toolbox reason to answer it differently, and they answered it
 * differently anyway: NOW-68K kept the half-typed line across a walk and
 * returned NULL for "there is nothing further that way", while the
 * PowerPC guest blanked the field at both ends of the walk and lost
 * whatever was half typed. That is the drift docs/command-parity.md
 * exists to prevent, one layer below the faces it usually talks about.
 *
 * It sits beside the guests rather than in one of them because a file
 * named for one guest and compiled by the other is a name that lies -
 * the shape contract/ already uses for wire_limits.h and share_path.h.
 * Unlike proc_quit_args.c (which is a COPY per guest, because NOW-68K
 * forbids the printf family and its message building had to be
 * rewritten), nothing here formats anything, so one file serves both
 * literally rather than by inspection.
 *
 * No malloc/NewPtr/NewHandle, no Toolbox calls, no printf family - the
 * intersection of what both targets allow, which is what lets it be one
 * file at all.
 *
 * STATIC BUDGET: lines[8][256] = 2048 B, pending[256], plus three
 * scalars = ~2316 bytes. Each console holds exactly one of these; on the
 * 68K side conwin.c says so in its own budget comment, that being the
 * 384 KB partition where it matters.
 *
 * WHY 8 DEEP: this stores what a human TYPED, not what scrolled past.
 * Eight entries is more recall than anyone needs while sitting at a
 * PowerBook, and every extra one costs a whole 256-byte line.
 *
 * WHY 256 WIDE, and not something snugger: it has to be >= the widest
 * line either guest's input field can hold, or recall becomes a silent
 * lie. NOW-68K's `launch` takes a full HFS colon path up to 199
 * characters (commands68.c's kNameMax), so a 128-byte history would
 * store a long path truncated, hand it back on the next Up as if it were
 * what was typed, and launch - or fail to find - something the human
 * never asked for. That is the same defect commands68.c's
 * trim_and_unquote already refuses to commit at the other end of the
 * same string. conwin.c's input buffer is 256 for exactly this reason,
 * the PowerPC page's is kConsoleMaxCols, and the test asserts this cap
 * is at least as wide as both.
 */
#ifndef NOW_CONSOLE_HISTORY_H
#define NOW_CONSOLE_HISTORY_H

enum {
    kConsoleHistoryCapacity = 8,
    kConsoleHistoryLineCap  = 256  /* 255 characters plus the NUL - above */
};

typedef struct {
    char lines[kConsoleHistoryCapacity][kConsoleHistoryLineCap];

    /* Total lines ever pushed, not clamped to capacity - the slot holding
     * the Nth-newest entry is (total_pushed - N) % capacity. Same idiom as
     * n68_console_ring.h, and for the same reason: no separate head/tail
     * bookkeeping to get wrong. */
    unsigned long total_pushed;

    /* How far back the cursor has walked. 0 = editing a fresh line (nothing
     * recalled); 1 = the newest entry; the count = the oldest still kept. */
    int depth;

    /* The line that was in the field when the walk STARTED, saved so that
     * arrowing back down past the newest entry restores it instead of
     * blanking it. This is the behaviour every shell has and the one whose
     * absence is noticed immediately: type half a command, press Up to
     * check something, press Down, and the half-typed command is still
     * there. */
    char pending[kConsoleHistoryLineCap];
} ConsoleHistory;

void console_history_init(ConsoleHistory *h);

/* Number of entries currently retained (<= kConsoleHistoryCapacity). */
int console_history_count(const ConsoleHistory *h);

/* Records one entered line and rewinds the cursor to the fresh-line
 * position, so the next Up starts from the newest entry again.
 *
 * A line that is empty, or that is byte-identical to the newest entry, is
 * NOT stored - repeating a command should not push the one before it out of
 * an eight-deep ring. The cursor is still rewound in both cases: pressing
 * Return always means "done with this line", whether or not it was worth
 * remembering.
 */
void console_history_push(ConsoleHistory *h, const char *line);

/* Walks one entry older (the Up arrow). `current` is whatever the input
 * field holds right now; on the FIRST step of a walk it is saved as the
 * pending line, so a later walk back down can restore it. May be NULL,
 * treated as "".
 *
 * Returns the text the field should now show, or NULL if there is nothing
 * older - already at the oldest retained entry, or nothing stored at all.
 * NULL means leave the field exactly as it is; it never means "clear it".
 * The returned pointer is into `h` and stays valid until the next push. */
const char *console_history_prev(ConsoleHistory *h, const char *current);

/* Walks one entry newer (the Down arrow). Returns the text the field should
 * now show - which at the end of the walk is the pending line saved by the
 * first console_history_prev, possibly "" - or NULL if the cursor is already
 * at the fresh-line position, meaning leave the field alone. */
const char *console_history_next(ConsoleHistory *h);

#endif /* NOW_CONSOLE_HISTORY_H */
