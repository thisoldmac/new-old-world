#include "mirror_anchor.h"

#include <stddef.h>
#include <string.h>

/* The widest an occupied slot can be as JSON, counted from the emitter's
   own format string with every number at its longest. Stated as an
   arithmetic bound rather than a guessed constant so that widening a
   field forces this line to be edited beside it. */
enum {
    kSlotJsonWorstCase = 22        /* the literal punctuation and keys */
        + 4                        /* "slot": up to two digits and comma */
        + (kMirrorAnchorNameMax * 2) /* every name byte escaped */
        + 11 + 11 + 11 + 11        /* four unsigned longs, decimal */
        + 24,                      /* the four keys' names */
    /* Room left for the object that wraps the array and for the rest of
       the reply's tail. Cheap, and the alternative is a reply that is one
       byte too long and therefore not JSON at all. */
    kSlotJsonReserve = 96
};

int now_mirror_anchor_slot_budget(long cap, long used)
{
    long room;
    long slots;

    if (cap <= 0 || used < 0 || used >= cap) {
        return 0;
    }
    room = cap - used - (long)kSlotJsonReserve;
    if (room <= 0) {
        return 0;
    }
    slots = room / (long)kSlotJsonWorstCase;
    if (slots > (long)kNowPeekMaxAnchors) {
        slots = (long)kNowPeekMaxAnchors;
    }
    return (int)slots;
}

/* Pascal string out of the resident's field into a C string.
 *
 * Bounded by what we WRITE, exactly as the extension's own capture is:
 * the length byte came out of another process's low memory and is not
 * ours to trust. A byte that is not printable ASCII is dropped rather
 * than passed through, because this string goes into JSON and into a
 * console line, and a stray control character in either is a defect that
 * looks like a parser bug. */
static void pascal_to_c(const unsigned char *src, char *dst)
{
    int len;
    int i;
    int n = 0;

    dst[0] = '\0';
    if (src == NULL) {
        return;
    }
    len = (int)src[0];
    if (len > (int)(kMirrorAnchorNameMax - 1)) {
        len = (int)(kMirrorAnchorNameMax - 1);
    }
    for (i = 1; i <= len; ++i) {
        unsigned char c = src[i];
        if (c >= 0x20 && c < 0x7f) {
            dst[n++] = (char)c;
        }
    }
    dst[n] = '\0';
}

void now_mirror_anchor_read(const NowPeekTable *table,
                            unsigned long now_ticks,
                            int slot_budget,
                            MirrorAnchorFacts *out)
{
    unsigned long need;
    int i;
    int has_name;

    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof *out);
    if (table == NULL) {
        return;
    }
    out->now_ticks = now_ticks;
    /* The accretive length rule, once per independently-appended region,
       exactly as mirror_probe.c gates the transport probe and the
       channel apart. These six counters arrived together, so they are
       one gate; the slot array itself predates them and is gated on its
       own extent below. */
    need = (unsigned long)(offsetof(NowPeekTable, anchor_last_publish_ticks)
                           + sizeof(NowPeekU32));
    if (table->length >= need) {
        out->present = 1;
        out->event_passes = table->anchor_event_passes;
        out->slot_scans = table->anchor_slot_scans;
        out->full_publishes = table->anchor_full_publishes;
        out->change_publishes = table->anchor_change_publishes;
        out->cadence_publishes = table->anchor_cadence_publishes;
        out->last_publish_ticks = table->anchor_last_publish_ticks;
    }
    /* The slots and the count are P1's original region and are readable
       from a resident far older than the counters above - so they are
       reported even when `present` is false, and a caller that finds
       slots with no counters is looking at exactly that build. */
    need = (unsigned long)(offsetof(NowPeekTable, anchors)
                           + sizeof table->anchors);
    if (table->length < need) {
        return;
    }
    out->count = table->anchor_count;
    has_name = table->anchor_format >= kNowPeekAnchorFormatV3;
    if (slot_budget <= 0 || slot_budget > (int)kNowPeekMaxAnchors) {
        slot_budget = (int)kNowPeekMaxAnchors;
    }
    for (i = 0; i < (int)kNowPeekMaxAnchors; ++i) {
        const NowPeekAnchorSlot *slot = &table->anchors[i];
        MirrorAnchorSlotFact *fact;
        unsigned long s1 = slot->stamp_ticks;
        unsigned long a5;
        unsigned long wl;
        char name[kMirrorAnchorNameMax];

        /* An unstamped slot was never captured. Reported as absent
           rather than as an empty row: "the filter has never run in any
           context" and "it ran and wrote nothing here" are the two
           answers this whole reader exists to separate, and a row of
           zeroes would read as the second when it is the first. */
        if (s1 == 0 || slot->a5 == 0) {
            continue;
        }
        /* The same seqlock the oracle reads by, for the same reason: the
           filter can rewrite this slot between our two stamp reads, and a
           torn row here would name the wrong application. A slot caught
           mid-update is skipped, not repaired. */
        a5 = slot->a5;
        wl = slot->window_list;
        if (has_name) {
            pascal_to_c(slot->cur_ap_name, name);
        } else {
            name[0] = '\0';
        }
        if (slot->stamp_ticks != s1) {
            continue;
        }
        if (out->slot_count >= slot_budget) {
            ++out->slots_omitted;
            continue;
        }
        fact = &out->slots[out->slot_count++];
        fact->slot = i;
        memcpy(fact->name, name, sizeof name);
        fact->a5 = a5;
        fact->window_list = wl;
        fact->stamp_ticks = s1;
        /* Unsigned subtraction, so a TickCount that wrapped past the
           stamp yields the true elapsed count rather than a huge one -
           the same arithmetic peek_oracle.c does, and free. */
        fact->age_ticks = now_ticks - s1;
    }
}
