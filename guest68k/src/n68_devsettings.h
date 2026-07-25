#ifndef N68_DEVSETTINGS_H
#define N68_DEVSETTINGS_H

/*
 * The DEV-ONLY settings file: parser half.
 *
 * NOW-68K has no preferences, and that is a product property, not an
 * oversight - main.c's header and the README both say so, and window.c
 * leaves Host blank at every launch for exactly that reason. Nothing here
 * changes that. What this adds is a file the LAB drops next to the
 * application so a build under test does not cost a walk to the PowerBook
 * and a retyped IP address. A shipped copy has no such file, and with no
 * file the application behaves exactly as it did before this existed: every
 * field is typed by a human, nothing is remembered between launches.
 *
 * That asymmetry is the whole design rule here: A SETTINGS FILE MUST NEVER
 * MAKE THE APPLICATION WORSE THAN HAVING NONE. So there is no failure mode
 * that stops startup, no dialog, and no all-or-nothing parse - a line the
 * parser cannot make sense of is counted and skipped, and the good lines
 * around it still apply. The worst a garbage file can do is behave like an
 * absent one.
 *
 * Toolbox-free by construction (the caller hands over bytes it has already
 * read), so this compiles and runs unchanged under the host cc for its test
 * and under Retro68 68K - the same split connfields.c and json_scan.c use.
 * The File Manager half, which finds and reads the file beside the
 * application, is n68_devsettings_file.h.
 *
 * ---- The file format ------------------------------------------------
 *
 * A human hand-edits this on a 1993 laptop in TeachText, so it is lines of
 * `key = value` and nothing else - no sections, no quoting, no escapes,
 * nothing whose absence is a syntax error:
 *
 *     # NOW-68K dev settings - lab only, never shipped
 *     host = 10.91.5.47
 *     port = 5250
 *     retry = on
 *     retry-interval = 5
 *     autoconnect = off
 *     launch-search-seconds = 20
 *
 * Rules, and why each one is this way:
 *
 *   - A line ends at CR, LF, or CRLF, and the last line needs no
 *     terminator. This file gets authored on a Mac and edited on macOS,
 *     so both endings WILL occur, sometimes in the same file after a
 *     round trip through a text editor that "helpfully" converts.
 *   - Blank lines are ignored. A line whose first non-blank character is
 *     '#' or ';' is a comment - two markers because a human writing a
 *     config file reaches for whichever one their other tools use, and
 *     there is no cost to accepting both.
 *   - Key and value are separated by '=', ':', or plain whitespace. The
 *     separator is not the interesting part of the line, and refusing
 *     `host 10.0.0.1` over it would be pedantry.
 *   - Keys are matched case-insensitively, and '_' and '-' are the same
 *     character ("retry_interval" and "retry-interval" both work). Nobody
 *     should have to remember which convention this one file chose.
 *   - Surrounding whitespace on key and value is trimmed; interior
 *     whitespace in a value is not, and every value this file accepts is
 *     whitespace-free anyway, so an interior space is a rejection.
 *   - A repeated key: last one wins. That is what editing-by-appending
 *     produces, which is how a file like this actually gets changed at
 *     2 a.m. beside a laptop.
 *
 * ---- What a malformed line does -------------------------------------
 *
 * It is skipped, counted in `bad_lines`, and its 1-based number recorded
 * in `first_bad_line`. It is NOT a parse failure: every other line in the
 * file still takes effect. "Malformed" covers a line with no separator, an
 * unknown key, an over-long key or value, and a value the matching
 * validator rejects (a host that is not a dotted quad, a port outside
 * 1..65535, a retry interval or launch-search budget outside its range, a
 * boolean that is not one of the accepted spellings). Host and port go
 * through connfields.c's own
 * validators - the same ones the window applies to typed text - so a
 * settings file can never install an address or port the human could not
 * have typed themselves.
 *
 * A file that is entirely garbage therefore sets nothing, reports its bad
 * lines, and leaves the application in exactly the no-file state.
 */

#include "connfields.h"   /* kNowDefaultHostPort, the shared validators */

/* "255.255.255.255" is 15 characters; a longer host value is rejected as
 * malformed rather than truncated into something that coincidentally
 * validates (the same trap window.c's kHostTextCap comment names). */
#define kN68DevHostTextMax 16

/* Retry cadence bounds for the FILE, not for the wire. wire_set_retry()
 * owns the contract's only cadence obligation - the >= 1 s floor that stops
 * a misconfigured loop becoming a connect flood - and this parser does not
 * duplicate or bypass it: 0 is refused here as an obvious typo rather than
 * silently clamped, and everything accepted is passed to wire_set_retry()
 * for it to floor. The upper bound is a sanity limit on a hand-typed
 * number, not a protocol one. */
#define kN68DevRetryMinSecs 1
#define kN68DevRetryMaxSecs 3600

/* The cadence window.c uses when no file says otherwise - today's
 * hardcoded "Retry every 5s" checkbox. */
#define kN68DevRetryDefaultSecs 5

/* The whole-volume budget `launch <bare name>` gives its catalog search
 * (proc68.c :: cat_search_find). Stated HERE, in seconds, and not in
 * proc68.c, for two reasons:
 *
 *   - proc68.c's own bound is kLaunchSearchBudgetTicks - TICKS, 60 to the
 *     second - which is the right unit for a TickCount() comparison and the
 *     wrong one for a human editing a text file on a PowerBook at midnight.
 *     Nobody types 1200. The file's unit is seconds and says so in the key
 *     name, so there is no unit to remember or get wrong.
 *   - The number appears in two places that must agree (the compiled-in
 *     default and the file's default-when-absent), so it is written once
 *     here and proc68.c derives its tick count from it. The control-frame
 *     cap taught this project what happens when a limit is stated three
 *     times (AGENTS.md).
 *
 * Why the key exists at all: the truncation branch - the one that reports a
 * search that ran out of time rather than a clean "not found" - has never
 * executed anywhere, because the 180c's catalog completes in about two
 * seconds and the shipped budget is twenty. Shortening the budget from the
 * lab's file is the only way to watch that branch on real hardware without
 * editing the shipped constant.
 *
 * The bounds:
 *   - 1 s minimum, not 0. A budget of zero is not a lab tool, it is a
 *     `launch` that can never find anything and gives no hint why; and one
 *     second is already the finest value that changes behaviour, since
 *     kLaunchSearchSliceTicks makes the FIRST PBCatSearchSync call a full
 *     second regardless. A shorter number would buy nothing and cost the
 *     reader an explanation.
 *   - 600 s maximum. This is a sanity limit on a hand-typed number, in the
 *     same spirit as the retry interval's - a mistyped 12000 must not turn
 *     the bounded search back into the unbounded one that wedged a machine
 *     in this fleet. The double bound in proc68.c (per-call slice AND total
 *     budget) is untouched by this key; only the total moves. */
#define kN68DevLaunchSearchMinSecs     1
#define kN68DevLaunchSearchMaxSecs     600
#define kN68DevLaunchSearchDefaultSecs 20

typedef struct N68DevSettings {
    /* Each `have_*` says the file supplied that key AND the value passed
     * validation. A caller applies only the fields with have_* set and
     * leaves everything else at its no-file default - which is why a
     * partly-broken file degrades one key at a time. */
    int            have_host;
    unsigned long  host_addr;                     /* host byte order, as connfields.h */
    char           host_text[kN68DevHostTextMax]; /* as written, for the Host field */

    int            have_port;
    unsigned short port;

    int            have_retry;
    int            retry_on;

    int            have_retry_secs;
    unsigned short retry_secs;

    int            have_autoconnect;
    int            autoconnect;

    /* Seconds, as written. proc68.c converts to ticks - the file never
     * carries a tick count, and nothing outside proc68.c should have to
     * know that 60 of anything make a second. */
    int            have_launch_search_secs;
    unsigned short launch_search_secs;

    /* Diagnostics, so the caller can say one honest sentence about the
     * file instead of either lying about it or staying silent. */
    unsigned short keys_set;
    unsigned short bad_lines;
    unsigned short first_bad_line;   /* 1-based; 0 when there were none */
} N68DevSettings;

/* Clears every field to the no-file state. Always call this first; parse
 * only ever sets fields, so a caller that skipped init would read stack
 * garbage as "the file said so". */
void n68_devsettings_init(N68DevSettings *s);

/* Parses `length` bytes of file text into `s`. The buffer need not be
 * NUL-terminated and may contain anything at all - there is no input that
 * makes this function fail, because there is no useful thing to do about a
 * bad settings file except ignore the parts that are bad. A NULL buffer or
 * a length <= 0 (the empty file) is a no-op. */
void n68_devsettings_parse(N68DevSettings *s, const char *text, long length);

#endif /* N68_DEVSETTINGS_H */
