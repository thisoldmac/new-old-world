#include "act_ref.h"

#include <string.h>

/* No Toolbox and no clock here - see the header. */

static const char *kPrefixWindow = "now-window-";
static const char *kPrefixElement = "now-element-";

static const char *prefix_for(unsigned short kind)
{
    if (kind == kNowActRefWindow) {
        return kPrefixWindow;
    }
    if (kind == kNowActRefElement) {
        return kPrefixElement;
    }
    return NULL;
}

void now_act_ref_reset(NowActRefTable *table)
{
    if (table == NULL) {
        return;
    }
    memset(table, 0, sizeof *table);
}

static char hex_digit(unsigned long v)
{
    static const char *digits = "0123456789abcdef";

    return digits[v & 0xFUL];
}

int now_act_ref_format(unsigned short kind, const unsigned long words[4],
                       char *out, long cap)
{
    const char *prefix = prefix_for(kind);
    long        need;
    long        at;
    int         w;
    int         nib;

    if (prefix == NULL || out == NULL || words == NULL) {
        return 0;
    }
    need = (long)strlen(prefix) + 36 + 1;
    if (cap < need) {
        return 0;               /* never a truncated reference */
    }
    strcpy(out, prefix);
    at = (long)strlen(prefix);

    /* 8-4-4-4-12: the dashes fall after hex digits 8, 12, 16 and 20, so
       the loop counts digits and inserts rather than special-casing four
       separate words. */
    for (w = 0; w < 4; w++) {
        for (nib = 7; nib >= 0; nib--) {
            int digit = w * 8 + (7 - nib);

            if (digit == 8 || digit == 12 || digit == 16 || digit == 20) {
                out[at++] = '-';
            }
            out[at++] = hex_digit(words[w] >> (nib * 4));
        }
    }
    out[at] = '\0';
    return 1;
}

int now_act_ref_valid(unsigned short kind, const char *ref)
{
    const char *prefix = prefix_for(kind);
    size_t      plen;
    int         i;

    if (prefix == NULL || ref == NULL) {
        return 0;
    }
    plen = strlen(prefix);
    if (strlen(ref) != plen + 36) {
        return 0;
    }
    if (strncmp(ref, prefix, plen) != 0) {
        return 0;
    }
    for (i = 0; i < 36; i++) {
        char c = ref[plen + (size_t)i];

        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (c != '-') {
                return 0;
            }
            continue;
        }
        /* Lowercase only. The host compares against its own lowercased
           spelling, so an uppercase reference would be a reference that
           validates here and is refused there. */
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
            return 0;
        }
    }
    return 1;
}

NowActRefRow *now_act_ref_remember(NowActRefTable *table,
                                   const NowActRefRow *row,
                                   unsigned long ticks)
{
    unsigned long words[4];
    NowActRefRow *slot;

    if (table == NULL || row == NULL || prefix_for(row->kind) == NULL) {
        return NULL;
    }
    slot = &table->rows[table->next % kNowActRefSlots];
    table->next++;
    if (table->used < kNowActRefSlots) {
        table->used++;
    }
    *slot = *row;
    slot->minted_ticks = ticks;

    table->counter++;
    words[0] = ticks;
    words[1] = table->counter;
    words[2] = row->window_address ^ (row->control_handle << 1);
    words[3] = row->fingerprint ^ (row->psn_lo + (row->psn_hi << 8));
    if (!now_act_ref_format(row->kind, words, slot->ref,
                            (long)sizeof slot->ref)) {
        slot->ref[0] = '\0';
        return NULL;
    }
    return slot;
}

const NowActRefRow *now_act_ref_find(const NowActRefTable *table,
                                     const char *ref)
{
    unsigned int i;

    if (table == NULL || ref == NULL || ref[0] == '\0') {
        return NULL;
    }
    for (i = 0; i < kNowActRefSlots; i++) {
        const NowActRefRow *row = &table->rows[i];

        if (row->ref[0] != '\0' && strcmp(row->ref, ref) == 0) {
            return row;
        }
    }
    return NULL;
}

int now_act_ref_still_matches(const NowActRefRow *row,
                              unsigned long window_address,
                              unsigned long control_handle,
                              unsigned long fingerprint)
{
    if (row == NULL) {
        return 0;
    }
    /* All three, and the fingerprint is the one that catches the case
       the other two cannot: an element found again by title whose
       addresses have moved is a DIFFERENT element wearing the same
       name. Refusing it is the whole reason a reference is not a title. */
    return row->window_address == window_address
           && row->control_handle == control_handle
           && row->fingerprint == fingerprint;
}
