/* Reading the anchor plane's own counters, without a Macintosh.
 *
 * The assertions here are the ones the 2026-08-07 investigation needed
 * and could not make. Each is written as the QUESTION it answers, because
 * a reader of this file six months from now will be looking at
 * `ax_oracle_not_found` and wanting to know what this instrument can and
 * cannot tell them. */

#include <stdio.h>
#include <string.h>

#include "mirror_anchor.h"
#include "mirror_json.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("  FAIL %s\n", what);
        ++failures;
    }
}

/* A table long enough for everything, with `filled` occupied slots whose
   names are "App0", "App1", ... A whole table, not a fragment: the
   accretive length gates are part of what is under test. */
static void build_table(NowPeekTable *t, int filled)
{
    int i;

    memset(t, 0, sizeof *t);
    t->magic = kNowPeekTableMagic;
    t->length = (NowPeekU32)sizeof *t;
    t->anchor_format = kNowPeekAnchorFormatV3;
    t->anchor_count = (NowPeekU16)filled;
    t->anchor_event_passes = 4000;
    t->anchor_slot_scans = 12;
    t->anchor_full_publishes = 300;
    t->anchor_change_publishes = 40;
    t->anchor_cadence_publishes = 260;
    t->anchor_last_publish_ticks = 900;
    for (i = 0; i < filled && i < (int)kNowPeekMaxAnchors; ++i) {
        NowPeekAnchorSlot *s = &t->anchors[i];
        s->a5 = (NowPeekU32)(0x1000 + i);
        s->window_list = (NowPeekU32)(0x2000 + i);
        s->stamp_ticks = (NowPeekU32)(800 + i);
        s->cur_ap_name[0] = 4;
        s->cur_ap_name[1] = 'A';
        s->cur_ap_name[2] = 'p';
        s->cur_ap_name[3] = 'p';
        s->cur_ap_name[4] = (unsigned char)('0' + i);
    }
}

int main(void)
{
    NowPeekTable table;
    MirrorAnchorFacts facts;

    printf("mirror anchor reader\n");

    /* THE QUESTION THIS WHOLE READER EXISTS FOR: can a caller tell "the
       filter never ran while armed" from "it ran and anchored nothing"?
       Only if passes survive an empty slot table. */
    build_table(&table, 0);
    now_mirror_anchor_read(&table, 1000, 0, &facts);
    check(facts.present, "counters present on a full-length table");
    check(facts.event_passes == 4000, "passes survive an empty slot table");
    check(facts.slot_count == 0, "no occupied slots reported");

    /* And the converse: an occupied table reports WHO, because the name
       is the only field that identifies an application rather than an
       address range. */
    build_table(&table, 3);
    now_mirror_anchor_read(&table, 1000, 0, &facts);
    check(facts.slot_count == 3, "three occupied slots");
    check(facts.count == 3, "resident's own count carried through");
    check(strcmp(facts.slots[0].name, "App0") == 0, "slot 0 names its app");
    check(strcmp(facts.slots[2].name, "App2") == 0, "slot 2 names its app");
    check(facts.slots[0].a5 == 0x1000, "slot 0 carries its A5");
    check(facts.slots[2].age_ticks == 1000 - 802, "age is now minus stamp");

    /* A slot with a stamp and no A5, or an A5 and no stamp, was never
       captured. Reported as absent rather than as a row of zeroes: a
       zero row reads as "the filter ran here and found nothing", which
       is the opposite of what it means. */
    build_table(&table, 2);
    table.anchors[1].stamp_ticks = 0;
    now_mirror_anchor_read(&table, 1000, 0, &facts);
    check(facts.slot_count == 1, "an unstamped slot is not a row");

    /* TickCount wraps about every 2.2 years of uptime. A stamp on the
       far side of the wrap must age to a small number, not to four
       billion, or a caller reads a live anchor as ancient debris. */
    build_table(&table, 1);
    table.anchors[0].stamp_ticks = 0xFFFFFFF0UL;
    now_mirror_anchor_read(&table, 15, 0, &facts);
    check(facts.slots[0].age_ticks == 31, "age survives a TickCount wrap");

    /* A resident too short for the counters still has slots. Reporting
       `present` false rather than zero counters is the difference
       between "this build never counted" and "nothing happened". */
    build_table(&table, 2);
    table.length = (NowPeekU32)(offsetof(NowPeekTable, anchors)
                                + sizeof table.anchors);
    now_mirror_anchor_read(&table, 1000, 0, &facts);
    check(!facts.present, "short resident reports counters absent");
    check(facts.event_passes == 0, "absent counters read as zero");
    check(facts.slot_count == 2, "and its slots are still readable");

    /* A resident too short for the slot array reports nothing at all
       rather than reading past its own end. */
    build_table(&table, 2);
    table.length = (NowPeekU32)offsetof(NowPeekTable, anchors);
    now_mirror_anchor_read(&table, 1000, 0, &facts);
    check(facts.slot_count == 0, "a table shorter than its slots reads none");
    check(facts.count == 0, "and claims no count");

    /* An anchor format older than the name has no name to give. It must
       come back empty rather than as whatever bytes are in the field. */
    build_table(&table, 1);
    table.anchor_format = kNowPeekAnchorFormatV2;
    now_mirror_anchor_read(&table, 1000, 0, &facts);
    check(facts.slots[0].name[0] == '\0', "pre-V3 format yields no name");

    /* The budget, and the thing it must never do: report fewer slots
       than exist and say nothing about it. */
    build_table(&table, 5);
    now_mirror_anchor_read(&table, 1000, 2, &facts);
    check(facts.slot_count == 2, "budget bounds the slots reported");
    check(facts.slots_omitted == 3, "and the remainder is COUNTED");

    /* The budget arithmetic itself: a reply with no room must ask for no
       slots rather than for a negative number of them. */
    check(now_mirror_anchor_slot_budget(3072, 3060) == 0,
          "no room yields no slots");
    check(now_mirror_anchor_slot_budget(3072, 0) > 0,
          "an empty reply affords some");
    check(now_mirror_anchor_slot_budget(0, 0) == 0, "a zero cap affords none");

    /* END TO END, and the assertion that would have ended the 2026-08-07
       investigation on its first hour: the reply says which applications
       hold anchors, and it stays valid JSON when they do not all fit. */
    {
        MirrorFacts m;
        char out[3072];
        long n;

        memset(&m, 0, sizeof m);
        m.lifecycle = kMirrorLifecycleActive;
        build_table(&table, 4);
        now_mirror_anchor_read(&table, 1000, 0, &m.anchors);
        n = now_mirror_json(&m, 7, out, (long)sizeof out);
        check(n > 0 && n < (long)sizeof out, "reply fits its buffer");
        check(strstr(out, "\"anchors\":{") != NULL, "reply carries anchors");
        check(strstr(out, "\"eventPasses\":4000") != NULL,
              "reply carries the passes");
        check(strstr(out, "\"name\":\"App3\"") != NULL,
              "reply names the fourth application");
        check(out[n - 1] == '}', "reply is closed");

        /* The same facts into a buffer that cannot hold the slots. The
           object must still close, and it must say how many it dropped. */
        n = now_mirror_json(&m, 7, out, 700);
        check(n > 0 && n < 700, "small reply fits its buffer");
        check(strstr(out, "\"slotsOmitted\":0") == NULL,
              "a truncated list does not claim to be whole");
    }

    if (failures == 0) {
        printf("  ok\n");
        return 0;
    }
    printf("  %d failure(s)\n", failures);
    return 1;
}
