/* n68_swlist.c - implementation of n68_swlist.h. No Toolbox, no allocation,
 * no printf family (numfmt.h only, matching the rest of this guest), so
 * now-guest-68k/tests/test_swlist.c can compile and run it here. */

#include "n68_swlist.h"

#include "numfmt.h"

#include <string.h>

/* ---- the domain vocabulary --------------------------------------------- */

/* The contract's SoftwareList.domain enum, in the order the overview
 * reports. One table, read by the parser and by the word renderer, so a
 * domain cannot be spellable-in and unspellable-out. */
static const char *const k_domain_words[NOW68K_SWLIST_DOMAIN_COUNT] = {
    "apps", "extensions", "cdevs", "startup", "apple"
};

/* What a person reads in the overview. Separate from the wire word on
 * purpose: "cdevs" is what the contract calls the domain and "Control
 * Panels" is what the machine calls the folder, and the console should say
 * the second while the wire says the first. */
static const char *const k_domain_labels[NOW68K_SWLIST_DOMAIN_COUNT] = {
    "Applications", "Extensions", "Control Panels", "Startup Items",
    "Apple Menu"
};

N68SwDomain n68_swlist_domain(const char *word)
{
    int i;

    if (word == NULL || word[0] == '\0') {
        return kN68SwDomainNone;
    }
    for (i = 0; i < NOW68K_SWLIST_DOMAIN_COUNT; ++i) {
        if (strcmp(word, k_domain_words[i]) == 0) {
            return (N68SwDomain)(kN68SwDomainApps + i);
        }
    }
    return kN68SwDomainUnknown;
}

const char *n68_swlist_domain_word(N68SwDomain d)
{
    if (d < kN68SwDomainApps
        || d > (N68SwDomain)(kN68SwDomainApps
                             + NOW68K_SWLIST_DOMAIN_COUNT - 1)) {
        return "";
    }
    return k_domain_words[d - kN68SwDomainApps];
}

static const char *domain_label(N68SwDomain d)
{
    if (d < kN68SwDomainApps
        || d > (N68SwDomain)(kN68SwDomainApps
                             + NOW68K_SWLIST_DOMAIN_COUNT - 1)) {
        return "(none)";
    }
    return k_domain_labels[d - kN68SwDomainApps];
}

const char *n68_swlist_note_unknown_domain(void)
{
    return "no such domain on this Mac";
}

const char *n68_swlist_note_truncated(void)
{
    /* The BOUND is named, not alluded to, for the reason proc68.c names the
     * search budget in its own truncation sentence: "some were not listed"
     * and "48 were listed and there are more" are different pieces of news,
     * and the number is the difference between them. It is spelled out
     * rather than formatted because it is a compile-time constant and a
     * formatter here would be a second place for it to live. */
    return "the inventory stopped at this Mac's bound of 48 items";
}

const char *n68_swlist_note_root_only(void)
{
    return "PBCatSearch was unusable; only the volume root";
}

/* If those ever outgrow the field, the frame arithmetic in the header
 * stops holding - so it is a build failure, not a runtime surprise. sizeof
 * on a literal is its length plus the NUL. */
_Static_assert(sizeof "no such domain on this Mac" - 1
                   <= NOW68K_SWLIST_NOTE_MAX,
               "the unknown-domain note no longer fits the tail budget");
_Static_assert(sizeof "the inventory stopped at this Mac's bound of 48 items"
                   - 1 <= NOW68K_SWLIST_NOTE_MAX,
               "the truncation note no longer fits the tail budget");
/* And if the bound moves, the sentence above is wrong. There is no way to
 * check a number inside a literal at compile time, so this pins the number
 * instead: change one and this fails, which is the reminder to change the
 * other. */
_Static_assert(sizeof "PBCatSearch was unusable; only the volume root" - 1
                   <= NOW68K_SWLIST_NOTE_MAX,
               "the root-only note no longer fits the tail budget");
_Static_assert(NOW68K_SWLIST_APP_CACHE_MAX == 48,
               "n68_swlist_note_truncated() names 48 in prose - move both "
               "or neither");

/* ---- the cursor split --------------------------------------------------- */

int n68_swlist_split_cursor(long cursor, long enabled_count,
                            long *index, int *in_disabled)
{
    if (cursor < 1) {
        cursor = 1;   /* an absent cursor means the first page */
    }
    if (enabled_count < 0) {
        enabled_count = 0;
    }
    if (cursor <= enabled_count) {
        if (index != NULL) {
            *index = cursor;
        }
        if (in_disabled != NULL) {
            *in_disabled = 0;
        }
        return 1;
    }
    /* Past the live folder. The caller decides whether a disabled sibling
     * exists; what this answers is WHERE in it to resume, and that is
     * arithmetic the File Manager cannot help with. */
    if (index != NULL) {
        *index = cursor - enabled_count;
    }
    if (in_disabled != NULL) {
        *in_disabled = 1;
    }
    return 1;
}

/* ---- software.listing --------------------------------------------------- */

/* One entry's bytes, appended whole or not at all. The caller restores
 * `pos` on a 0 return: numfmt.h leaves it unspecified on failure. */
static int append_entry(const N68SwRow *row, int first,
                        char *out, long avail, long *pos)
{
    int ok = 1;

    ok = ok && now68k_fmt_append_str(out, avail, pos, first ? "{" : ",{");
    ok = ok && now68k_fmt_append_str(out, avail, pos, "\"name\":\"");
    ok = ok && now68k_json_append_escaped(out, avail, pos, row->name);
    /* `path` is required by the schema and empty is a MEANING - "not
     * launchable from afar" - so it is always emitted, never omitted to
     * save bytes. */
    ok = ok && now68k_fmt_append_str(out, avail, pos, "\",\"path\":\"");
    ok = ok && now68k_json_append_escaped(out, avail, pos, row->path);
    ok = ok && now68k_fmt_append_str(out, avail, pos, "\"");

    /* type and creator are optional, and a catalog read that produced
     * neither should say nothing rather than "". */
    if (row->file_type[0] != '\0') {
        ok = ok && now68k_fmt_append_str(out, avail, pos, ",\"type\":\"");
        ok = ok && now68k_json_append_escaped(out, avail, pos,
                                              row->file_type);
        ok = ok && now68k_fmt_append_str(out, avail, pos, "\"");
    }
    if (row->creator[0] != '\0') {
        ok = ok && now68k_fmt_append_str(out, avail, pos, ",\"creator\":\"");
        ok = ok && now68k_json_append_escaped(out, avail, pos, row->creator);
        ok = ok && now68k_fmt_append_str(out, avail, pos, "\"");
    }
    /* -1 is the contract's own word for "unreadable" and is therefore
     * emitted rather than suppressed - it is an answer. */
    ok = ok && now68k_fmt_append_str(out, avail, pos, ",\"sizeK\":");
    ok = ok && now68k_fmt_append_long(out, avail, pos, row->size_k);
    /* `off` only when it is TRUE. A false `off` is the default reading of
     * an absent field, and four bytes a row buys nothing on a frame this
     * size. The PowerPC guest sends it either way; the meaning is identical
     * and this side has less room. */
    if (row->off) {
        ok = ok && now68k_fmt_append_str(out, avail, pos, ",\"off\":true");
    }
    ok = ok && now68k_fmt_append_str(out, avail, pos, "}");
    return ok;
}

long n68_swlist_build(long id, const char *domain, long cursor,
                      const N68SwRow *rows, long row_count,
                      int more_beyond, const char *note,
                      char *out, long cap,
                      long *next_cursor, int *more)
{
    long avail = cap > 0 ? cap - 1 : 0;   /* one byte held for the NUL */
    long pos = 0;
    long emitted = 0;
    long i;
    int ok = 1;
    int left_over;

    if (cursor < 1) {
        cursor = 1;
    }
    if (domain == NULL) {
        domain = "";
    }
    if (next_cursor != NULL) {
        *next_cursor = cursor;
    }
    if (more != NULL) {
        *more = more_beyond ? 1 : 0;
    }
    if (out == NULL || avail <= 0) {
        return 0;
    }

    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                      "{\"type\":\"software.listing\","
                                      "\"id\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, id);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"domain\":\"");
    /* This build's own literal, but escaped anyway: the day someone passes
     * a host string through here, the escaping is already correct rather
     * than one review away from being wrong. */
    ok = ok && now68k_json_append_escaped(out, avail, &pos, domain);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\",\"entries\":[");
    if (!ok) {
        out[0] = '\0';
        return 0;
    }

    for (i = 0; i < row_count; ++i) {
        long saved = pos;

        /* Room for the tail is checked BEFORE committing to a row. A page
         * that spends its last bytes on an entry and then cannot close the
         * JSON decodes to nothing - the whole page lost to save one row. */
        if (!append_entry(&rows[i], emitted == 0, out, avail, &pos)
            || pos > avail - NOW68K_SWLIST_TAIL_MAX) {
            pos = saved;
            break;
        }
        ++emitted;
        if (emitted >= NOW68K_SWLIST_MAX_ROWS) {
            break;   /* the schema's maxItems, not our buffer */
        }
    }

    /* A page with rows left to give and none in it would make the host ask
     * again for the same cursor forever. */
    if (emitted == 0 && row_count > 0) {
        out[0] = '\0';
        return 0;
    }

    left_over = (emitted < row_count) || more_beyond;
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "],\"more\":");
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                      left_over ? "true" : "false");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"cursor\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, cursor + emitted);
    if (!ok) {
        out[0] = '\0';
        return 0;
    }

    /* The note is appended last and dropped WHOLE if it does not fit -
     * file.listing's rule for `root`, and for the same reason: half a note
     * truncates the frame mid-string and costs the entire listing. Built
     * into the live buffer and rolled back rather than staged in a second
     * one, because 100 bytes of stack for a sentence is not a trade this
     * partition needs to make. */
    if (note != NULL && note[0] != '\0') {
        long saved = pos;
        int fit = 1;

        fit = fit && now68k_fmt_append_str(out, avail, &pos, ",\"note\":\"");
        fit = fit && now68k_json_append_escaped(out, avail, &pos, note);
        fit = fit && now68k_fmt_append_str(out, avail, &pos, "\"");
        if (!fit || pos >= avail) {   /* one byte for the closing brace */
            pos = saved;
        }
    }

    if (!now68k_fmt_append_str(out, avail, &pos, "}") || pos <= 0) {
        out[0] = '\0';
        return 0;
    }
    out[pos] = '\0';
    if (next_cursor != NULL) {
        *next_cursor = cursor + emitted;
    }
    if (more != NULL) {
        *more = left_over ? 1 : 0;
    }
    return pos;
}

/* ---- the `sw` command --------------------------------------------------- */

/* KB, rounded down, the way n68_filelist_describe does it. Two tables on
 * one machine should not use two units. */
static int append_kb(char *out, long cap, long *pos, long bytes_k)
{
    return now68k_fmt_append_long(out, cap, pos, bytes_k);
}

void n68_swlist_describe(const N68SwRow *row, char *out, long cap)
{
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;
    int ok = 1;

    if (out == NULL || cap <= 0) {
        return;
    }
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                      row->file_type[0] != '\0'
                                          ? row->file_type : "????");
    if (row->creator[0] != '\0') {
        ok = ok && now68k_fmt_append_str(out, avail, &pos, "/");
        ok = ok && now68k_fmt_append_str(out, avail, &pos, row->creator);
    }
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "  ");
    if (row->size_k < 0) {
        ok = ok && now68k_fmt_append_str(out, avail, &pos, "? KB");
    } else {
        ok = ok && append_kb(out, avail, &pos, row->size_k);
        ok = ok && now68k_fmt_append_str(out, avail, &pos, " KB");
    }
    if (row->off) {
        ok = ok && now68k_fmt_append_str(out, avail, &pos, "  (off)");
    }
    if (!ok || pos < 0 || pos > avail) {
        pos = 0;   /* a description that did not fit says nothing rather
                    * than something half-written */
    }
    out[pos] = '\0';
}

void n68_swlist_rows(N68SwDomain d, const N68SwRow *rows, long row_count,
                     int more_beyond, int truncated, N68CmdRows *out)
{
    long i;

    if (out == NULL) {
        return;
    }
    n68_cmdrows_init(out);
    out->ok = 1;
    /* The output key the contract's `sw` x-command declares. */
    strcpy(out->key, "sw");

    (void)n68_cmdrows_add(out, "Domain", domain_label(d));

    for (i = 0; i < row_count; ++i) {
        char value[kN68CmdRowValueCap];

        n68_swlist_describe(&rows[i], value, (long)sizeof value);
        if (!n68_cmdrows_add(out, rows[i].name, value)) {
            more_beyond = 1;   /* the table filled before the domain did */
            break;
        }
    }

    /* TWO different short answers, said separately. `more_beyond` means the
     * page ended before the domain did and the rest is a software.list
     * away; `truncated` means the INVENTORY stopped at this machine's bound
     * and there is no cursor that will reach the rest. A reader shown only
     * one of them would draw the wrong conclusion about the other. */
    if (more_beyond) {
        (void)n68_cmdrows_add(out, "...", "more items follow");
    }
    if (truncated) {
        (void)n68_cmdrows_add(out, "!", n68_swlist_note_truncated());
    }
}

void n68_swlist_overview_rows(const N68SwCount *counts, N68CmdRows *out)
{
    int i;

    if (out == NULL) {
        return;
    }
    n68_cmdrows_init(out);
    out->ok = 1;
    strcpy(out->key, "sw");

    if (counts == NULL) {
        n68_cmdrows_set_error(out, "io-error",
                              "this Mac could not read its System Folder");
        return;
    }

    for (i = 0; i < NOW68K_SWLIST_DOMAIN_COUNT; ++i) {
        char value[kN68CmdRowValueCap];
        long avail = (long)sizeof value - 1;
        long pos = 0;
        int ok = 1;

        if (!counts[i].available) {
            /* "not on this Mac" and "zero items" are different facts. A
             * System 7.1 machine with no Extensions Manager has no disabled
             * folders at all, and reporting 0 would say it had them and
             * they were empty. */
            (void)n68_cmdrows_add(out, k_domain_labels[i], "(not on this Mac)");
            continue;
        }
        ok = ok && now68k_fmt_append_long(value, avail, &pos,
                                          counts[i].enabled);
        ok = ok && now68k_fmt_append_str(value, avail, &pos, " on");
        if (counts[i].disabled > 0) {
            ok = ok && now68k_fmt_append_str(value, avail, &pos, ", ");
            ok = ok && now68k_fmt_append_long(value, avail, &pos,
                                              counts[i].disabled);
            ok = ok && now68k_fmt_append_str(value, avail, &pos, " off");
        }
        if (counts[i].truncated) {
            ok = ok && now68k_fmt_append_str(value, avail, &pos, "+ (bound)");
        }
        if (!ok || pos < 0 || pos > avail) {
            pos = 0;
        }
        value[pos] = '\0';
        (void)n68_cmdrows_add(out, k_domain_labels[i], value);
    }
}

void n68_swlist_unknown_domain_rows(N68CmdRows *out)
{
    if (out == NULL) {
        return;
    }
    n68_cmdrows_init(out);
    n68_cmdrows_set_error(out, "bad-domain",
                          n68_swlist_note_unknown_domain());
}
