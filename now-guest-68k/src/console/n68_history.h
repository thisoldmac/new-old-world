/*
 * n68_history.h - the up/down-arrow command history for the interactive
 * console window (conwin.h).
 *
 * A fixed-capacity ring of recently entered lines plus one cursor that
 * walks it. Deliberately separate from the Toolbox: everything about
 * "which line should the input field show now" is decidable without a
 * TERec, a window or an event, so it is decided here and tested on the host
 * (now-guest-68k/tests/test_history.c). conwin.c is then only responsible for
 * putting the returned string into the field.
 *
 * No malloc/NewPtr/NewHandle, no Toolbox calls, no printf family.
 *
 * STATIC BUDGET: lines[8][256] = 2048 B, pending[256], plus three scalars
 * = ~2316 bytes. conwin.c holds exactly one of these in BSS and says so in
 * its own budget comment.
 *
 * WHY 8 DEEP: this stores what a human TYPED, not what scrolled past.
 * Eight entries is more recall than anyone needs while sitting at a
 * PowerBook, and every extra one costs a whole 256-byte line.
 *
 * WHY 256 WIDE, and not something snugger: it has to be >= the widest line
 * the input field can hold, or recall becomes a silent lie. `launch` takes
 * a full HFS colon path up to 199 characters (commands68.c's kNameMax), so
 * a 128-byte history would store a long path truncated, hand it back on the
 * next Up as if it were what was typed, and launch - or fail to find -
 * something the human never asked for. That is the same defect
 * commands68.c's trim_and_unquote already refuses to commit at the other
 * end of the same string. conwin.c's input buffer is 256 for exactly this
 * reason and the two numbers are meant to stay equal.
 */
#ifndef NOW68K_N68_HISTORY_H
#define NOW68K_N68_HISTORY_H

enum {
    kN68HistoryCapacity = 8,
    kN68HistoryLineCap  = 256    /* 255 characters plus the NUL - see above */
};

typedef struct {
    char lines[kN68HistoryCapacity][kN68HistoryLineCap];

    /* Total lines ever pushed, not clamped to capacity - the slot holding
     * the Nth-newest entry is (total_pushed - 1 - N) % kN68HistoryCapacity.
     * Same idiom as n68_console_ring.h, and for the same reason: no
     * separate head/tail bookkeeping to get wrong. */
    unsigned long total_pushed;

    /* How far back the cursor has walked. 0 = editing a fresh line (nothing
     * recalled); 1 = the newest entry; `stored` = the oldest still kept. */
    int depth;

    /* The line that was in the field when the walk STARTED, saved so that
     * arrowing back down past the newest entry restores it instead of
     * blanking it. This is the behaviour every shell has and the one whose
     * absence is noticed immediately: type half a command, press Up to
     * check something, press Down, and the half-typed command is still
     * there. */
    char pending[kN68HistoryLineCap];
} N68History;

void n68_history_init(N68History *h);

/* Number of entries currently retained (<= kN68HistoryCapacity). */
int n68_history_count(const N68History *h);

/* Records one entered line and rewinds the cursor to the fresh-line
 * position, so the next Up starts from the newest entry again.
 *
 * A line that is empty, or that is byte-identical to the newest entry, is
 * NOT stored - repeating a command should not push the one before it out of
 * an eight-deep ring. The cursor is still rewound in both cases: pressing
 * Return always means "done with this line", whether or not it was worth
 * remembering.
 */
void n68_history_push(N68History *h, const char *line);

/* Walks one entry older (the Up arrow). `current` is whatever the input
 * field holds right now; on the FIRST step of a walk it is saved as the
 * pending line, so a later walk back down can restore it. May be NULL,
 * treated as "".
 *
 * Returns the text the field should now show, or NULL if there is nothing
 * older - already at the oldest retained entry, or nothing stored at all.
 * NULL means leave the field exactly as it is; it never means "clear it".
 * The returned pointer is into `h` and stays valid until the next push. */
const char *n68_history_prev(N68History *h, const char *current);

/* Walks one entry newer (the Down arrow). Returns the text the field should
 * now show - which at the end of the walk is the pending line saved by the
 * first n68_history_prev, possibly "" - or NULL if the cursor is already at
 * the fresh-line position, meaning leave the field alone. */
const char *n68_history_next(N68History *h);

#endif /* NOW68K_N68_HISTORY_H */
