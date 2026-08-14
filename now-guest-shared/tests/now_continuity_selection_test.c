/* The selection stub table's two decisions, watched without a Macintosh.
   The refusal cases are the ones worth the file: a grab reads a file
   OUTSIDE the Files share on the host's word, and these four checks are
   the whole of what stands between that word and the disk. */
#include <stdio.h>
#include <string.h>

#include "now_continuity_selection.h"

#define CHECK(value) do { if (!(value)) {                                \
    fprintf(stderr, "selection stub failed at line %d\n", __LINE__);     \
    return 1;                                                            \
} } while (0)

static NowContinuityStubItem item_named(const char *name, long dir,
                                        unsigned long modified, int folder)
{
    NowContinuityStubItem it;

    memset(&it, 0, sizeof it);
    it.volume_ref = -1;
    it.dir_id = dir;
    strcpy(it.name, name);
    it.modified = modified;
    it.is_folder = folder;
    it.file_type = folder ? 0UL : 0x54455854UL;   /* 'TEXT' */
    it.creator = folder ? 0UL : 0x74747874UL;     /* 'ttxt' */
    it.data_size = folder ? 0 : 4096;
    return it;
}

int main(void)
{
    NowContinuityStubTable table;
    NowContinuityStubItem a = item_named("Report", 42, 1000, 0);
    NowContinuityStubItem b = item_named("Report", 42, 1000, 0);
    NowContinuityStubItem edited = item_named("Report", 42, 2000, 0);
    NowContinuityStubItem elsewhere = item_named("Report", 99, 1000, 0);
    NowContinuityStubItem folder = item_named("Projects", 42, 1000, 1);

    /* --- identity ---------------------------------------------------- */
    CHECK(now_continuity_stub_same(&a, &b));
    CHECK(!now_continuity_stub_same(&a, &edited));
    CHECK(!now_continuity_stub_same(&a, &elsewhere));
    b.volume_ref = -2;
    CHECK(!now_continuity_stub_same(&a, &b));
    b = a;
    strcpy(b.name, "report");             /* HFS is case-insensitive, the
                                             DISPLAYED name is not: a
                                             rename a person can see is a
                                             change they expect us to see */
    CHECK(!now_continuity_stub_same(&a, &b));

    /* --- generations -------------------------------------------------- */
    now_continuity_stub_reset(&table, 7);
    CHECK(table.generation == 0 && !table.have_item);
    /* An empty poll on an empty table says nothing: silence is correct
       here and is the ordinary case. */
    CHECK(now_continuity_stub_observe(&table, (const NowContinuityStubItem *)0)
          == 0);
    CHECK(table.generation == 0);

    CHECK(now_continuity_stub_observe(&table, &a) == 1);
    CHECK(table.generation == 1 && table.have_item);
    /* The same item again at any cadence must cost nothing. */
    CHECK(now_continuity_stub_observe(&table, &a) == 0);
    CHECK(now_continuity_stub_observe(&table, &a) == 0);
    CHECK(table.generation == 1);

    /* Sizes moving under an unchanged date refresh the cache without a
       generation: the host holds a stub that is still true. */
    {
        NowContinuityStubItem grown = a;
        grown.data_size = 8192;
        CHECK(now_continuity_stub_observe(&table, &grown) == 0);
        CHECK(table.generation == 1);
        CHECK(table.item.data_size == 8192);
    }

    CHECK(now_continuity_stub_observe(&table, &edited) == 1);
    CHECK(table.generation == 2);

    /* Deselecting is a change, and it gets a generation of its own —
       otherwise the host cannot tell "nothing is selected" from "the poll
       stopped running". */
    CHECK(now_continuity_stub_observe(&table, (const NowContinuityStubItem *)0)
          == 1);
    CHECK(table.generation == 3 && !table.have_item);
    CHECK(now_continuity_stub_observe(&table, (const NowContinuityStubItem *)0)
          == 0);
    CHECK(table.generation == 3);

    /* --- the grant ---------------------------------------------------- */
    now_continuity_stub_reset(&table, 7);
    CHECK(now_continuity_grab_check(&table, 7, 7, 1) == kNowGrabNoSelection);
    (void)now_continuity_stub_observe(&table, &a);          /* generation 1 */

    CHECK(now_continuity_grab_check(&table, 7, 7, 1) == kNowGrabOK);

    /* THE MUTATION THIS FILE EXISTS FOR: a generation that is not the
       current one is refused, in both directions. Serving a stale one
       would hand over an item the person consented to while looking at
       something else. */
    CHECK(now_continuity_grab_check(&table, 7, 7, 2)
          == kNowGrabStaleSelection);
    (void)now_continuity_stub_observe(&table, &edited);     /* generation 2 */
    CHECK(now_continuity_grab_check(&table, 7, 7, 1)
          == kNowGrabStaleSelection);
    CHECK(now_continuity_grab_check(&table, 7, 7, 2) == kNowGrabOK);
    CHECK(now_continuity_grab_check(&table, 7, 7, 0)
          == kNowGrabStaleSelection);

    /* The epoch is checked against the LIVE one, not the table's, so a
       table left behind by a finished session grants nothing. */
    CHECK(now_continuity_grab_check(&table, 0, 7, 2) == kNowGrabBadEpoch);
    CHECK(now_continuity_grab_check(&table, 8, 7, 2) == kNowGrabBadEpoch);
    CHECK(now_continuity_grab_check(&table, 8, 8, 2) == kNowGrabBadEpoch);
    CHECK(now_continuity_grab_check((const NowContinuityStubTable *)0, 7, 7, 2)
          == kNowGrabBadEpoch);

    /* A folder is refused by name. The stub said isFolder, so the host
       could see it coming; an empty file would not have told anyone. */
    now_continuity_stub_reset(&table, 9);
    (void)now_continuity_stub_observe(&table, &folder);
    CHECK(now_continuity_grab_check(&table, 9, 9, 1) == kNowGrabFolderNotYet);

    /* Every refusal has a contract code and success has none. */
    CHECK(now_continuity_grab_code(kNowGrabOK) == (const char *)0);
    CHECK(strcmp(now_continuity_grab_code(kNowGrabBadEpoch),
                 "bad-epoch") == 0);
    CHECK(strcmp(now_continuity_grab_code(kNowGrabStaleSelection),
                 "stale-selection") == 0);
    CHECK(strcmp(now_continuity_grab_code(kNowGrabNoSelection),
                 "no-selection") == 0);
    CHECK(strcmp(now_continuity_grab_code(kNowGrabFolderNotYet),
                 "folder-not-yet") == 0);

    printf("continuity selection stub ok\n");
    return 0;
}
