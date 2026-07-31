#include "diag_layout.h"

#include <stdio.h>
#include <string.h>

/* Plain field assignment throughout: SetRect is Toolbox, and this file
   also runs under the host's cc. */
static void set_rect(Rect *r, short left, short top, short right,
                     short bottom)
{
    r->left = left;
    r->top = top;
    r->right = right;
    r->bottom = bottom;
}

static void clear_rect(Rect *r)
{
    r->left = 0;
    r->top = 0;
    r->right = 0;
    r->bottom = 0;
}

/* How many lines of body a state draws. A state with rows draws rows
   instead; a state with neither draws nothing and the card shrinks to its
   header, which is what an absent probe should cost. */
static int body_lines(DiagProbe probe, DiagCardState state)
{
    char line[192];
    int n = 0;
    int i;

    for (i = 0; i < kDiagBodyLines; ++i) {
        if (diag_body_line(probe, state, i, line, (long)sizeof line) > 0) {
            n = i + 1;
        }
    }
    return n;
}

static short card_height(DiagProbe probe, DiagCardState state, short rows)
{
    short h = (short)(kDiagCardInset + kDiagTitleHeight
                      + kDiagLineHeight        /* what it measures */
                      + kDiagLineHeight);      /* what it costs */

    if (state == kDiagRows && rows > 0) {
        h = (short)(h + 4 + rows * kDiagRowHeight);
    } else {
        int n = body_lines(probe, state);

        if (n > 0) {
            h = (short)(h + 4 + n * kDiagLineHeight);
        }
    }
    return (short)(h + kDiagCardInset);
}

void diag_layout_compute(const Rect *body, const DiagCardState *states,
                         const short *rows, DiagLayout *out)
{
    short left = (short)(body->left + kDiagMargin);
    short right = (short)(body->right - kDiagMargin);
    short y = 0;
    int i;

    set_rect(&out->canvas, left, (short)(body->top + 8),
             (short)(right - kDiagScrollBarWidth + 1),
             (short)(body->bottom - 8));
    set_rect(&out->scrollbar, (short)(out->canvas.right - 1),
             out->canvas.top, (short)(out->canvas.right - 1
                                      + kDiagScrollBarWidth),
             out->canvas.bottom);

    for (i = 0; i < kDiagProbeCount; ++i) {
        DiagCardLayout *card = &out->cards[i];
        short card_left = (short)(out->canvas.left + 4);
        short card_right = (short)(out->canvas.right - 4);
        short inner_left = (short)(card_left + kDiagCardInset);
        short inner_right = (short)(card_right - kDiagCardInset);
        short top = y;
        short line;
        const char *button;

        set_rect(&card->card, card_left, top, card_right,
                 (short)(top + card_height((DiagProbe)i, states[i],
                                           rows[i])));
        line = (short)(top + kDiagCardInset);
        set_rect(&card->title, inner_left, line, inner_right,
                 (short)(line + kDiagTitleHeight));
        line = card->title.bottom;
        set_rect(&card->measures, inner_left, line, inner_right,
                 (short)(line + kDiagLineHeight));
        line = card->measures.bottom;
        set_rect(&card->cost, inner_left, line, inner_right,
                 (short)(line + kDiagLineHeight));
        set_rect(&card->body, inner_left, (short)(card->cost.bottom + 4),
                 inner_right, (short)(card->card.bottom - kDiagCardInset));

        button = diag_button_title((DiagProbe)i, states[i]);
        if (button == NULL) {
            /* No control at all, rather than a disabled one: a greyed
               button with no explanation is what reads as broken. */
            clear_rect(&card->button);
        } else {
            set_rect(&card->button,
                     (short)(inner_right - kDiagButtonWidth),
                     (short)(card->title.top - 2), inner_right,
                     (short)(card->title.top - 2 + kDiagButtonHeight));
            /* The title must not run under the button. */
            card->title.right = (short)(card->button.left - 8);
        }
        y = (short)(card->card.bottom + kDiagCardGap);
    }
    out->content_height = (short)(y > 0 ? y - kDiagCardGap : 0);
}

Boolean diag_probe_served(DiagProbe probe)
{
    switch (probe) {
    case kDiagVProbe:
        return 1;
    case kDiagPutStat:
        return 1;
    default:
        /* shotdiag is the 68K guest's capture diagnostic. Nothing in the
           Carbon guest answers it, and nothing should: this Mac's capture
           path is not the one it was written to explain. */
        return 0;
    }
}

const char *diag_probe_title(DiagProbe probe)
{
    switch (probe) {
    case kDiagVProbe:
        return "Screen read speed";
    case kDiagShotDiag:
        return "Capture diagnosis";
    default:
        return "Last file received";
    }
}

const char *diag_probe_verb(DiagProbe probe)
{
    switch (probe) {
    case kDiagVProbe:
        return "vprobe";
    case kDiagShotDiag:
        return "shotdiag";
    default:
        return "putstat";
    }
}

const char *diag_probe_measures(DiagProbe probe)
{
    switch (probe) {
    case kDiagVProbe:
        return "What reading this Mac's screen memory costs, by method.";
    case kDiagShotDiag:
        return "Where a 68K Mac's screen capture reads its pixels from.";
    default:
        return "Where the time went in the last file this Mac received.";
    }
}

const char *diag_probe_cost(DiagProbe probe)
{
    switch (probe) {
    case kDiagVProbe:
        /* Said before it is spent, not after: three seconds of frozen
           screen is alarming when it is a surprise and unremarkable when
           it was announced. */
        return "About three seconds. Leave the screen still while it runs.";
    case kDiagShotDiag:
        return "Instant, on the Mac that serves it.";
    default:
        return "Instant - it reads counters this Mac already keeps.";
    }
}

const char *diag_button_title(DiagProbe probe, DiagCardState state)
{
    if (state == kDiagAbsent) {
        return NULL;
    }
    if (state == kDiagRunning) {
        return "Measuring";
    }
    if (probe == kDiagPutStat) {
        return "Read";
    }
    return state == kDiagReady ? "Run" : "Run Again";
}

long diag_body_line(DiagProbe probe, DiagCardState state, int index,
                    char *out, long cap)
{
    out[0] = '\0';
    switch (state) {
    case kDiagAbsent:
        /* Not an error, and it must not look like one. The verb is not in
           this guest's command table, which is a fact about which NOW
           guest this is rather than about whether the Mac is well - so the
           line names the sibling that answers it and stops. */
        if (index == 0) {
            snprintf(out, (size_t)cap,
                     "Not available on this Mac: %s is not in this "
                     "guest's commands.", diag_probe_verb(probe));
        } else if (index == 1) {
            /* Which sibling answers it, named rather than implied. Only
               shotdiag is absent here today; the other branch is what a
               build too old for a probe would say, and saying "the 68K
               guest" about vprobe - which both guests serve - would be a
               confident wrong answer. */
            strncpy(out, probe == kDiagShotDiag
                             ? "Nothing is wrong with the machine - the "
                               "68K guest is the one that serves it."
                             : "Nothing is wrong with the machine - this "
                               "build predates the measurement.",
                    (size_t)cap - 1);
            out[cap - 1] = '\0';
        }
        break;
    case kDiagReady:
        if (index == 0) {
            strncpy(out, "Not measured yet in this launch.",
                    (size_t)cap - 1);
            out[cap - 1] = '\0';
        }
        break;
    case kDiagRunning:
        if (index == 0) {
            strncpy(out, "Measuring...", (size_t)cap - 1);
            out[cap - 1] = '\0';
        }
        break;
    case kDiagNothingYet:
        /* The zeroes that are not shown, explained. Every counter here is
           legitimately zero and a table of them would read as a failed
           probe, which is the opposite of what it means. */
        if (index == 0) {
            strncpy(out, "No file has reached this Mac yet, so there is "
                         "no transfer to describe.", (size_t)cap - 1);
            out[cap - 1] = '\0';
        } else if (index == 1) {
            strncpy(out, "These counters fill in the moment one arrives.",
                    (size_t)cap - 1);
            out[cap - 1] = '\0';
        }
        break;
    default:
        break;
    }
    return (long)strlen(out);
}

void diag_status_text(const DiagCardState *states, char *out, long cap)
{
    int served = 0;
    int i;

    /* No "measuring" line, deliberately. The probes run synchronously, so
       while one is running nothing repaints the placard - the card paints
       its own running line before the call and the event loop is not
       reached again until the answer is in. A branch here would be a
       sentence nobody can ever see. */
    for (i = 0; i < kDiagProbeCount; ++i) {
        if (states[i] != kDiagAbsent) {
            ++served;
        }
    }
    snprintf(out, (size_t)cap,
             "%d of %d diagnostics run on this Mac; the rest belong to "
             "the other guest.", served, (int)kDiagProbeCount);
}

Boolean diag_putstat_has_run(const DiagPutStat *stats)
{
    /* Any one of them moving means a transfer happened. A file of zero
       bytes still costs a chunk and a pass through the receive path, so
       there is no arrival this misses. */
    return (stats->chunks != 0 || stats->writes != 0 || stats->bytes != 0
            || stats->us_total != 0) ? 1 : 0;
}

static void label_row(DiagRow *row, const char *label)
{
    strncpy(row->label, label, sizeof row->label - 1);
    row->label[sizeof row->label - 1] = '\0';
}

enum { kDiagPutStatRows = 7 };

int diag_putstat_rows(const DiagPutStat *stats, DiagRow *rows, int max)
{
    int n = 0;

    if (max < kDiagPutStatRows) {
        return 0;
    }
    label_row(&rows[n], "Bytes");
    snprintf(rows[n++].value, sizeof rows[0].value, "%ld", stats->bytes);
    label_row(&rows[n], "Chunks");
    snprintf(rows[n++].value, sizeof rows[0].value, "%ld", stats->chunks);
    label_row(&rows[n], "Writes");
    snprintf(rows[n++].value, sizeof rows[0].value, "%ld", stats->writes);
    label_row(&rows[n], "In FSWrite");
    snprintf(rows[n++].value, sizeof rows[0].value, "%lu ms",
             stats->us_write / 1000);
    label_row(&rows[n], "In receive");
    snprintf(rows[n++].value, sizeof rows[0].value, "%lu ms",
             stats->us_total / 1000);
    /* Resume has no other visible trace: without this row a resumed
       transfer and a fresh one look identical from here. */
    label_row(&rows[n], "Resumed from");
    snprintf(rows[n++].value, sizeof rows[0].value, "%ld",
             stats->resumed_from);
    label_row(&rows[n], "CRC-32");
    snprintf(rows[n++].value, sizeof rows[0].value, "%08lx", stats->crc);
    return n;
}
