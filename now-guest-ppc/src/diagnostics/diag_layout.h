#ifndef NOW_DIAG_LAYOUT_H
#define NOW_DIAG_LAYOUT_H

/* Rectangle arithmetic, availability and sentence choice for the
   Diagnostics page. No Toolbox calls live here, so the same file compiles
   under the host's cc for the native test
   (now-guest-ppc/tests/diag_layout_test.c) - the pattern software_layout.c
   set.

   Three measurements, one card each, stacked and scrolled rather than
   selected from a list. The reason is availability rather than taste: the
   probes are served by different guests, so on any one machine some of
   them are absent, and a card can say that in place where a selection
   hides it behind a click nobody makes. A card for a probe this guest
   does not serve carries no control at all - a dead button is the thing
   this page must not be.

   The second absence this page has to render is subtler. `putstat`
   describes the LAST file this Mac received, so a Mac that has received
   nothing answers eleven legitimate zeroes - which is the visual shape of
   a failure and is nothing of the kind. It gets a state of its own. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef struct Rect {
    short top;
    short left;
    short bottom;
    short right;
} Rect;
typedef unsigned char Boolean;
#endif

typedef enum {
    kDiagVProbe = 0,
    kDiagShotDiag,
    kDiagPutStat,
    kDiagWireStat,       /* fourth instrument: how long this Mac takes to
                             notice the wire, read rather than run - see
                             below */
    kDiagProbeCount
} DiagProbe;

typedef enum {
    kDiagAbsent = 0,   /* this guest does not serve it */
    kDiagReady,        /* served, not measured in this launch */
    kDiagRunning,
    kDiagRows,         /* measured, and there is something to show */
    kDiagNothingYet,   /* measured, but what it describes never happened */
    kDiagRefused       /* the probe answered with a reason instead */
} DiagCardState;

typedef struct DiagRow {
    char label[24];
    char value[48];
} DiagRow;

enum {
    kDiagMargin = 12,
    kDiagScrollBarWidth = 16,
    kDiagCardGap = 10,
    kDiagCardInset = 10,      /* card frame to its content */
    kDiagTitleHeight = 17,
    kDiagLineHeight = 15,
    kDiagRowHeight = 14,
    kDiagButtonWidth = 62,
    kDiagButtonHeight = 20,
    kDiagRowLabelWidth = 132,
    kDiagBodyLines = 2,       /* the most sentences any state needs */
    kDiagMaxRows = 20         /* vprobe's own ceiling */
};

typedef struct DiagCardLayout {
    Rect card;                /* the framed card, in CONTENT coordinates */
    Rect title;               /* name and verb */
    Rect measures;
    Rect cost;
    Rect button;              /* all zero when the card has no control */
    Rect body;                /* sentences or rows draw from here down */
} DiagCardLayout;

typedef struct DiagLayout {
    Rect canvas;              /* body coordinates: the scrolled viewport */
    Rect scrollbar;           /* body coordinates */
    DiagCardLayout cards[kDiagProbeCount];
    short content_height;     /* every card plus the gaps between them */
} DiagLayout;

/* `rows` is how many result rows each card currently holds; a state that
   shows no rows ignores it. Card rectangles come back in CONTENT
   coordinates - subtract the scroll offset to draw them. */
void diag_layout_compute(const Rect *body, const DiagCardState *states,
                         const short *rows, DiagLayout *out);

/* Whether THIS guest serves a probe. It is a fact about the Carbon
   guest's own command table, stated where the page can render it rather
   than discovered by asking and getting an error - the 68K sibling's copy
   of this page answers differently, and neither is a judgement about the
   machine. */
Boolean diag_probe_served(DiagProbe probe);

const char *diag_probe_title(DiagProbe probe);
const char *diag_probe_verb(DiagProbe probe);
const char *diag_probe_measures(DiagProbe probe);
const char *diag_probe_cost(DiagProbe probe);

/* The button's word, or NULL when this state has no control. */
const char *diag_button_title(DiagProbe probe, DiagCardState state);

/* Sentence `index` (0..kDiagBodyLines-1) for a card, or 0 length when
   this state has no such line. */
long diag_body_line(DiagProbe probe, DiagCardState state, int index,
                    char *out, long cap);

void diag_status_text(const DiagCardState *states, char *out, long cap);

/* The receive counters `putstat` reads, as plain scalars so this file
   stays Toolbox-free. */
typedef struct DiagPutStat {
    long chunks;
    long writes;
    long bytes;
    long resumed_from;
    unsigned long us_write;
    unsigned long us_total;
    unsigned long crc;
} DiagPutStat;

/* Whether this Mac has received anything at all. All-zero counters are a
   legitimate answer meaning "nothing has arrived", not a measurement, and
   the difference is the whole reason this predicate exists. */
Boolean diag_putstat_has_run(const DiagPutStat *stats);

/* The page's reading of the same counters the `putstat` command sends.
   Fewer rows than the wire's: the wire is for a machine that will keep
   them, this is for a person looking at a screen. Returns the row count. */
int diag_putstat_rows(const DiagPutStat *stats, DiagRow *rows, int max);

/* A distribution, reduced to what fits a row: n/mean/min/max plus the
   ONE bucket the median falls in (range and count), rather than the
   wire's full ten-bucket histogram. Same reduction putstat already makes
   for the same reason - a person reading a card wants the shape, not
   the instrument's full resolution. `median_bucket` is -1 with no
   samples; `median_hi_us` is 0 for the open-ended last bucket, the same
   sentinel the wire's own rendering uses. */
typedef struct DiagLoopStat {
    long n;
    unsigned long mean_us;
    unsigned long min_us;
    unsigned long max_us;
    int median_bucket;
    long median_lo_us;
    long median_hi_us;
    long median_count;
} DiagLoopStat;

/* The `wirestat` report's read-only half, as plain scalars - the counters
   conn_wake_stats() and conn_idle_sleep() already keep, translated the
   same way FileReceiveStats becomes a DiagPutStat. Wake and sleep are
   SET only from the console or the wire (wirestat_cmd.c); this card has
   no control for either, so nothing here can change what it reads. */
typedef struct DiagWireStat {
    long sleep_now_ticks;
    long idle_sleep_ticks;
    Boolean wake_on;
    Boolean notifier_live;
    long data_events;
    long wake_calls;
    DiagLoopStat pass;          /* interval between the wire's service passes */
    DiagLoopStat wake;          /* T_DATA notification -> the read that took it */
} DiagWireStat;

/* The page's reading of the same report the `wirestat` command sends -
   one implementation of the distribution math (loopstat.c), two
   renderings: JSON rows there, a card here. Returns the row count, or 0
   when `max` cannot hold it (a ceiling, never a truncation). */
int diag_wirestat_rows(const DiagWireStat *stats, DiagRow *rows, int max);

#endif /* NOW_DIAG_LAYOUT_H */
