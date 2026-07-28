#include "census.h"
#include "json.h"

#include <stdio.h>
#include <string.h>

/* census.report serialization. Pure C - no Toolbox - so the native test
   compiles this file with the host cc and the wire shape is provable off
   the machine. The conformance suite on the host side reads this file;
   the report is assembled across several snprintf calls, so it carries a
   hand-written fixture there (GuestWireFixtureTests) - the row loop below
   is why. */

const char *census_outcome_name(CensusOutcome outcome)
{
    switch (outcome) {
    case kCensusPresent:      return "present";
    case kCensusAbsent:       return "absent";
    case kCensusPartial:      return "partial";
    case kCensusRefused:      return "refused";
    case kCensusFailed:       return "failed";
    case kCensusNotAttempted: return "not-attempted";
    }
    return "failed";
}

/* Append formatted text at *pos; nonzero and untouched *pos on overflow,
   so one check at the end suffices. */
static int overflowed(char *out, long cap, long *pos, const char *text)
{
    long n = (long)strlen(text);

    if (*pos + n >= cap) {
        return 1;
    }
    memcpy(out + *pos, text, (size_t)n);
    *pos += n;
    out[*pos] = '\0';
    return 0;
}

long census_report_json(const char *probe, long id, const CensusPage *page,
                        char *out, long cap)
{
    char head[160];
    char esc[2 * kCensusRowMeaningCap];
    char cell[2 * kCensusRowMeaningCap + 16];
    long pos = 0;
    int i;
    int count = page->count;

    if (count > kCensusPageMax) {
        return -1;              /* a page that breaks its own cap is a bug */
    }
    snprintf(head, sizeof head,
             "{\"type\":\"census.report\",\"id\":%ld,\"probe\":\"%s\","
             "\"outcome\":\"%s\",\"rows\":[",
             id, probe, census_outcome_name(page->outcome));
    if (overflowed(out, cap, &pos, head)) {
        return -1;
    }
    for (i = 0; i < count; i++) {
        const CensusRow *row = &page->rows[i];
        const char *fields[3];
        int f;

        fields[0] = row->name;
        fields[1] = row->raw;
        fields[2] = row->meaning;
        if (overflowed(out, cap, &pos, i > 0 ? ",[" : "[")) {
            return -1;
        }
        for (f = 0; f < 3; f++) {
            now_json_escape(fields[f], esc, (long)sizeof esc);
            snprintf(cell, sizeof cell, "%s\"%s\"", f > 0 ? "," : "", esc);
            if (overflowed(out, cap, &pos, cell)) {
                return -1;
            }
        }
        if (overflowed(out, cap, &pos, "]")) {
            return -1;
        }
    }
    snprintf(head, sizeof head, "],\"more\":%s",
             page->more ? "true" : "false");
    if (overflowed(out, cap, &pos, head)) {
        return -1;
    }
    if (page->more) {
        snprintf(head, sizeof head, ",\"cursor\":%ld", page->next_cursor);
        if (overflowed(out, cap, &pos, head)) {
            return -1;
        }
    }
    if (page->total >= 0) {
        snprintf(head, sizeof head, ",\"total\":%ld", page->total);
        if (overflowed(out, cap, &pos, head)) {
            return -1;
        }
    }
    if (page->note[0] != '\0') {
        now_json_escape(page->note, esc, (long)sizeof esc);
        snprintf(cell, sizeof cell, ",\"note\":\"%s\"", esc);
        if (overflowed(out, cap, &pos, cell)) {
            return -1;
        }
    }
    if (overflowed(out, cap, &pos, "}")) {
        return -1;
    }
    return pos;
}
