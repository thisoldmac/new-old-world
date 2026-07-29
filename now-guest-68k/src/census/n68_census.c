/*
 * n68_census.c - implementation of n68_census.h: the page, the wire
 * renderer and the console renderer, side by side where they cannot drift.
 *
 * No Toolbox, no malloc/NewPtr/NewHandle, no printf family (numfmt.h only,
 * matching wire68.c and n68_cmdresult.c) - this file compiles and is tested
 * under the host cc by now-guest-68k/tests/test_census.c.
 */
#include "n68_census.h"

#include "numfmt.h"

#include <string.h>

/* Copies `s` into `dst`, truncating at cap-1, and reduces every byte to
 * printable ASCII on the way. See the header for why this is here rather
 * than in an escaper: a census row is a fact, and a frame whose size is
 * arithmetic is worth more than a diacritic in a volume name.
 *
 * '"' and '\\' are sanitized like any other unwelcome byte rather than
 * escaped, so the JSON below can append these strings between two quotes
 * with nothing in between to go wrong. A NULL `s` is an empty field. */
static void clean_copy(char *dst, long cap, const char *s)
{
    long i = 0;

    if (cap <= 0) {
        return;
    }
    if (s != NULL) {
        for (; s[i] != '\0' && i < cap - 1; ++i) {
            unsigned char c = (unsigned char)s[i];

            dst[i] = (c >= 32 && c < 127 && c != '"' && c != '\\')
                         ? (char)c : '.';
        }
    }
    dst[i] = '\0';
}

void n68_census_page_init(N68CensusPage *page, long cursor)
{
    if (page == NULL) {
        return;
    }
    memset(page, 0, sizeof *page);
    page->skip = (cursor > 0) ? cursor : 0;
    page->outcome = kN68CensusPresent;
}

int n68_census_page_add(N68CensusPage *page, const char *name,
                         const char *raw, const char *meaning)
{
    N68CensusRow *row;

    if (page == NULL) {
        return 0;
    }
    /* Counted BEFORE anything else, and unconditionally: `seen` is the
     * probe's total row count, which is what the report's `total` field
     * promises, and a row skipped by the cursor or lost to a full page is
     * still a row this machine has. */
    ++page->seen;
    if (page->seen <= page->skip) {
        return 0;
    }
    if (page->count >= kN68CensusRowsMax) {
        page->overflow = 1;
        return 0;
    }
    row = &page->rows[page->count++];
    clean_copy(row->name, (long)sizeof row->name, name);
    clean_copy(row->raw, (long)sizeof row->raw, raw);
    clean_copy(row->meaning, (long)sizeof row->meaning, meaning);
    return 1;
}

void n68_census_page_say(N68CensusPage *page, N68CensusOutcome outcome,
                          const char *note)
{
    if (page == NULL) {
        return;
    }
    page->outcome = outcome;
    clean_copy(page->note, (long)sizeof page->note, note);
}

const char *n68_census_outcome_name(N68CensusOutcome outcome)
{
    switch (outcome) {
    case kN68CensusPresent:      return "present";
    case kN68CensusAbsent:       return "absent";
    case kN68CensusPartial:      return "partial";
    case kN68CensusRefused:      return "refused";
    case kN68CensusFailed:       return "failed";
    case kN68CensusNotAttempted: return "not-attempted";
    }
    /* An outcome this build does not know is a bug in this build, not a
     * finding about the machine - and "failed" is the only word in the
     * vocabulary that says "something went wrong here" without claiming
     * anything about the hardware. */
    return "failed";
}

/* One row as `,["name","raw","meaning"]`, appended whole or not at all.
 * Half a row is a frame that stops mid-JSON, which decodes to nothing on
 * the host and costs the WHOLE report rather than one row - the same rule
 * n68_cmdrows_render_json states for its tables. */
static int append_row(char *out, long cap, long *pos, const N68CensusRow *row,
                      int first)
{
    long try_pos = *pos;
    int ok = 1;

    ok = ok && now68k_fmt_append_str(out, cap, &try_pos, first ? "[\"" : ",[\"");
    ok = ok && now68k_fmt_append_str(out, cap, &try_pos, row->name);
    ok = ok && now68k_fmt_append_str(out, cap, &try_pos, "\",\"");
    ok = ok && now68k_fmt_append_str(out, cap, &try_pos, row->raw);
    ok = ok && now68k_fmt_append_str(out, cap, &try_pos, "\",\"");
    ok = ok && now68k_fmt_append_str(out, cap, &try_pos, row->meaning);
    ok = ok && now68k_fmt_append_str(out, cap, &try_pos, "\"]");
    if (!ok) {
        return 0;               /* *pos untouched: nothing half-written */
    }
    *pos = try_pos;
    return 1;
}

long n68_census_report_json(const char *probe, long id,
                             const N68CensusPage *page, char *out, long cap)
{
    char safe_probe[kN68CensusProbeCap];
    long pos = 0;
    long tail;
    int written = 0;
    int more;
    int ok = 1;
    int i;

    if (out == NULL || cap <= 0) {
        return 0;
    }
    out[0] = '\0';
    if (page == NULL) {
        return 0;
    }
    /* The probe name comes from the peer. It is sanitized in wire68.c
     * before it reaches here and sanitized AGAIN here, because this
     * function is also called by the `census` verb's path and by a native
     * test, and a string that can break the JSON we transmit must be
     * unable to do so from every direction it can arrive from. */
    clean_copy(safe_probe, (long)sizeof safe_probe, probe);

    ok = ok && now68k_fmt_append_str(out, cap, &pos,
                                      "{\"type\":\"census.report\",\"id\":");
    ok = ok && now68k_fmt_append_long(out, cap, &pos, id);
    ok = ok && now68k_fmt_append_str(out, cap, &pos, ",\"probe\":\"");
    ok = ok && now68k_fmt_append_str(out, cap, &pos, safe_probe);
    ok = ok && now68k_fmt_append_str(out, cap, &pos, "\",\"outcome\":\"");
    ok = ok && now68k_fmt_append_str(out, cap, &pos,
                                      n68_census_outcome_name(page->outcome));
    ok = ok && now68k_fmt_append_str(out, cap, &pos, "\",\"rows\":[");
    if (!ok) {
        out[0] = '\0';
        return 0;
    }

    /* Rows go in until the buffer says stop, and the ones that do not fit
     * are not lost - they are what `cursor` points at. The reservation is
     * the tail: a report that spent its last bytes on a row and could not
     * then say `more` would silently end a probe halfway through. */
    tail = cap - NOW68K_CENSUS_TAIL_MAX;
    for (i = 0; i < page->count; ++i) {
        if (!append_row(out, tail > 0 ? tail : 0, &pos, &page->rows[i],
                        written == 0)) {
            break;
        }
        ++written;
    }

    more = (written < page->count) || page->overflow;
    ok = ok && now68k_fmt_append_str(out, cap, &pos, "],\"more\":");
    ok = ok && now68k_fmt_append_str(out, cap, &pos, more ? "true" : "false");
    if (more) {
        ok = ok && now68k_fmt_append_str(out, cap, &pos, ",\"cursor\":");
        /* From what was WRITTEN, not from what was gathered. A cursor that
         * counted the rows the page holds would skip the ones the frame
         * could not carry, and the caller would never learn they existed. */
        ok = ok && now68k_fmt_append_long(out, cap, &pos,
                                           page->skip + (long)written);
    }
    ok = ok && now68k_fmt_append_str(out, cap, &pos, ",\"total\":");
    ok = ok && now68k_fmt_append_long(out, cap, &pos, page->seen);
    if (page->note[0] != '\0') {
        ok = ok && now68k_fmt_append_str(out, cap, &pos, ",\"note\":\"");
        ok = ok && now68k_fmt_append_str(out, cap, &pos, page->note);
        ok = ok && now68k_fmt_append_str(out, cap, &pos, "\"");
    }
    ok = ok && now68k_fmt_append_str(out, cap, &pos, "}");
    if (!ok || pos <= 0 || pos >= cap) {
        out[0] = '\0';
        return 0;
    }
    out[pos] = '\0';
    return pos;
}

/* The status row a page gets when the rows alone would not tell the truth:
 * "(pram) partial - 20 of 256 bytes". */
static void status_row(const char *probe, const N68CensusPage *page,
                       N68CmdRows *out, int more)
{
    /* Built WIDER than the row they go into, and handed to
     * n68_cmdrows_add, which truncates at its own members' capacities.
     * One truncation rule rather than two that could disagree - and a note
     * longer than the value column comes out cut mid-sentence rather than
     * dropped for not fitting, which is the more useful half of nothing. */
    char label[kN68CmdRowLabelCap + 1];
    char value[kN68CensusNoteCap + 32];
    long pos = 0;

    /* Every append below is checked, because numfmt.h leaves *pos
     * unspecified on a failure and a chain that kept appending past one
     * would be writing from an unknown offset. The fallbacks are short
     * enough that they cannot themselves fail at these capacities. */
    if (now68k_fmt_append_str(label, (long)sizeof label, &pos, "(")
        && now68k_fmt_append_str(label, (long)sizeof label, &pos, probe)
        && now68k_fmt_append_str(label, (long)sizeof label, &pos, ")")
        && pos < (long)sizeof label) {
        label[pos] = '\0';
    } else {
        /* A probe name too long for the label column still needs a row -
         * the outcome is the part a person came for. */
        strcpy(label, "(probe)");
    }

    pos = 0;
    if (!now68k_fmt_append_str(value, (long)sizeof value, &pos,
                                n68_census_outcome_name(page->outcome))
        || pos >= (long)sizeof value) {
        strcpy(value, "?");
    } else {
        long after_outcome = pos;

        /* The outcome word goes in FIRST and is never given up: if the
         * note does not fit beside it, the row still says `partial` rather
         * than saying nothing. */
        if (page->note[0] != '\0') {
            if (!(now68k_fmt_append_str(value, (long)sizeof value, &pos, " - ")
                  && now68k_fmt_append_str(value, (long)sizeof value, &pos,
                                            page->note))
                || pos >= (long)sizeof value) {
                pos = after_outcome;
            }
        } else if (more) {
            if (!now68k_fmt_append_str(value, (long)sizeof value, &pos,
                                        " (more follows)")
                || pos >= (long)sizeof value) {
                pos = after_outcome;
            }
        }
        value[pos] = '\0';
    }
    n68_cmdrows_add(out, label, value);
}

void n68_census_rows(const char *probe, const N68CensusPage *page,
                      N68CmdRows *out)
{
    char safe_probe[kN68CensusProbeCap];
    int more;
    int i;

    if (out == NULL || page == NULL) {
        return;
    }
    clean_copy(safe_probe, (long)sizeof safe_probe, probe);
    more = page->overflow;

    out->ok = 1;
    /* The output key the contract names for this verb, so the host reads
     * output.census whether the rows came from here or from the PowerPC
     * guest's own run_census. */
    if (out->key[0] == '\0') {
        clean_copy(out->key, (long)sizeof out->key, "census");
    }
    for (i = 0; i < page->count; ++i) {
        /* The contract collapses [name, raw, meaning] to [name, meaning]
         * for a text surface, and the raw value folds into the meaning
         * column when a row has no decoded form - so a value this build
         * could not decode still reaches the person who asked. */
        const char *value = page->rows[i].meaning[0] != '\0'
                                ? page->rows[i].meaning
                                : page->rows[i].raw;

        if (!n68_cmdrows_add(out, page->rows[i].name, value)) {
            more = 1;
            break;
        }
    }
    if (page->count == 0 || page->outcome != kN68CensusPresent
        || page->note[0] != '\0' || more) {
        status_row(safe_probe, page, out, more);
    }
}
