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

    /* --- the grant that outlives its epoch ---------------------------- */

    /* The gesture ENDS the epoch it started in: crossing back to the host
       is what ends host ownership. Measured on metal 2026-08-14 as
       "selection dropped: the Continuity epoch ended" firing before any
       drop could have happened. */
    {
        NowContinuityGrantHold hold;
        const NowContinuityStubItem *serve;
        int after;
        /* The table's epoch as the guest tracks it. Kept in step with the
           resets below so the settle inside resolve is a no-op here: this
           block is about the DECISION, and the block after it is about the
           transition nobody had run yet. */
        unsigned long tepoch = 11;

        now_continuity_grant_release(&hold);
        now_continuity_stub_reset(&table, 11);
        (void)now_continuity_stub_observe(&table, &a);      /* generation 1 */
        CHECK(now_continuity_grab_resolve(&table, &hold, &tepoch, 11, 11, 1, 1000,
                                          &serve, &after) == kNowGrabOK);
        CHECK(after == 0 && serve == &table.item);

        /* The epoch ends under the held gesture. */
        now_continuity_grant_hold(&hold, &table, 1000);
        now_continuity_stub_reset(&table, 0);
        tepoch = 0;
        CHECK(hold.epoch == 11 && hold.generation == 1);

        /* THE MUTATION THIS BLOCK EXISTS FOR: without the hold this is
           bad-epoch, and the drag a person is still holding is refused. */
        CHECK(now_continuity_grab_resolve(&table, &hold, &tepoch, 0, 11, 1, 1200,
                                          &serve, &after) == kNowGrabOK);
        CHECK(after == 1 && serve == &hold.item);
        /* Still true once the NEXT epoch is live but has published
           nothing: the gesture is older than that epoch. */
        now_continuity_stub_reset(&table, 12);
        tepoch = 12;
        CHECK(now_continuity_grab_resolve(&table, &hold, &tepoch, 12, 11, 1, 1200,
                                          &serve, &after) == kNowGrabOK);
        CHECK(after == 1);

        /* It is ONE generation of ONE ended epoch, and nothing else. */
        tepoch = 0;
        now_continuity_stub_reset(&table, 0);
        CHECK(now_continuity_grab_resolve(&table, &hold, &tepoch, 0, 11, 2,
                                          1200, &serve, &after)
              == kNowGrabBadEpoch);
        CHECK(now_continuity_grab_resolve(&table, &hold, &tepoch, 0, 10, 1,
                                          1200, &serve, &after)
              == kNowGrabBadEpoch);
        CHECK(serve == (const NowContinuityStubItem *)0 && after == 0);

        /* And it closes by the clock, named as its own refusal rather than
           as bad-epoch: the request had the right shape and arrived late. */
        CHECK(now_continuity_grab_resolve(
                  &table, &hold, &tepoch, 0, 11, 1,
                  1000 + kNowContinuityGrantTicks + 1, &serve, &after)
              == kNowGrabGrantExpired);
        CHECK(now_continuity_grab_resolve(
                  &table, &hold, &tepoch, 0, 11, 1,
                  1000 + kNowContinuityGrantTicks, &serve, &after)
              == kNowGrabOK);

        /* A stale generation under a LIVE epoch stays stale-selection —
           the hold must not launder it. */
        now_continuity_stub_reset(&table, 12);
        tepoch = 12;
        (void)now_continuity_stub_observe(&table, &edited);  /* gen 1 of 12 */
        CHECK(now_continuity_grab_resolve(&table, &hold, &tepoch, 12, 12, 9,
                                          1200, &serve, &after)
              == kNowGrabStaleSelection);

        /* A folder held across the boundary is still refused by name. */
        {
            NowContinuityStubTable folders;
            NowContinuityGrantHold folder_hold;
            unsigned long fepoch = 13;

            now_continuity_grant_release(&folder_hold);
            now_continuity_stub_reset(&folders, 13);
            (void)now_continuity_stub_observe(&folders, &folder);
            now_continuity_grant_hold(&folder_hold, &folders, 1000);
            now_continuity_stub_reset(&folders, 0);
            fepoch = 0;
            CHECK(now_continuity_grab_resolve(&folders, &folder_hold, &fepoch,
                                              0, 13, 1, 1100, &serve, &after)
                  == kNowGrabFolderNotYet);
        }

        /* An epoch that ended holding nothing holds nothing, and it must
           overwrite whatever the previous one left. */
        now_continuity_stub_reset(&table, 14);
        tepoch = 14;
        now_continuity_grant_hold(&hold, &table, 2000);
        CHECK(hold.epoch == 0);
        now_continuity_stub_reset(&table, 0);
        tepoch = 0;
        CHECK(now_continuity_grab_resolve(&table, &hold, &tepoch, 0, 11, 1,
                                          2000, &serve, &after)
              == kNowGrabBadEpoch);
    }

    /* --- the transition nobody had run yet ----------------------------
       THE METAL ORDERING, measured 2026-08-15 01:04. The host stands down
       for a drag it is still holding, so continuity.disarm and
       continuity.grab arrive together and the guest dispatches both in one
       pass — before the Finder poll that used to be the only thing that
       took the grant out of the dying epoch. The grab was therefore the
       FIRST code to notice the epoch had ended, and it noticed by
       answering bad-epoch: the exact refusal the contract says this window
       exists to prevent, three seconds into a thirty-second window.

       Nothing settles the table in this block on purpose. That is the
       mutation: put the settle back under the poll's cadence — take it out
       of now_continuity_grab_resolve — and the first CHECK below reads
       bad-epoch. The block above cannot catch it, because it hands resolve
       a table somebody already moved. */
    {
        NowContinuityStubTable live;
        NowContinuityGrantHold hold;
        const NowContinuityStubItem *serve;
        unsigned long tepoch = 0;
        int after;

        now_continuity_grant_release(&hold);
        CHECK(now_continuity_selection_settle(&live, &hold, &tepoch, 2, 500));
        (void)now_continuity_stub_observe(&live, &a);   /* epoch 2, gen 1 */
        CHECK(tepoch == 2 && live.generation == 1 && live.have_item);
        /* Settling onto the epoch already running changes nothing. */
        CHECK(now_continuity_selection_settle(&live, &hold, &tepoch, 2, 600)
              == 0);

        /* The epoch ends. NOBODY POLLS. The grab is what notices. */
        CHECK(now_continuity_grab_resolve(&live, &hold, &tepoch, 0, 2, 1, 680,
                                          &serve, &after) == kNowGrabOK);
        CHECK(after == 1 && serve == &hold.item);
        CHECK(tepoch == 0 && hold.epoch == 2 && hold.generation == 1);
        CHECK(strcmp(serve->name, "Report") == 0);

        /* bad-epoch is NOT narrowed to nothing: an epoch this guest never
           had is still refused by that name, on this same path. */
        CHECK(now_continuity_grab_resolve(&live, &hold, &tepoch, 0, 3, 1, 700,
                                          &serve, &after) == kNowGrabBadEpoch);
        CHECK(serve == (const NowContinuityStubItem *)0);

        /* And the window still closes by the clock — grant-expired, which
           is a different sentence from bad-epoch and the only one worth
           trying again. */
        CHECK(now_continuity_grab_resolve(
                  &live, &hold, &tepoch, 0, 2, 1,
                  680 + kNowContinuityGrantTicks + 1, &serve, &after)
              == kNowGrabGrantExpired);
    }

    /* --- the last check, and the wrong-file case itself -------------------

       METAL, 2026-08-15 17:19. `hello.txt` was the published generation,
       Michelle pressed on `main.c` and dragged it across the edge, and the
       grab named the generation it had every right to name. Every check
       above says yes to that grab. This is the one that says no.

       Watched failing against today's code: with confirm_serve_against_finder
       absent from now_continuity_selection_grab, the guest hands out
       `hello.txt` and the person watches the wrong file arrive. */
    {
        NowContinuityStubItem serving = item_named("hello.txt", 42, 1000, 0);
        NowContinuityStubItem dragged = item_named("main.c", 42, 3000, 0);
        NowContinuityStubItem touched = item_named("hello.txt", 42, 9999, 0);

        /* The Mac still holds what the grab names: serve it. */
        CHECK(now_continuity_grab_confirm(&serving, 1, &serving)
              == kNowGrabOK);
        /* Identity, not freshness. A file saved between the publish and the
           grab is still the file being dragged, and refusing it here would
           be this guard inventing a defect of its own. */
        CHECK(now_continuity_stub_same(&serving, &touched) == 0);
        CHECK(now_continuity_grab_confirm(&serving, 1, &touched)
              == kNowGrabOK);
        /* THE WRONG FILE. */
        CHECK(now_continuity_grab_confirm(&serving, 1, &dragged)
              == kNowGrabStaleSelection);
        /* Same name, different folder — the identity triple, not the name. */
        CHECK(now_continuity_grab_confirm(&serving, 1, &elsewhere)
              == kNowGrabStaleSelection);
        /* Nothing selected any more. */
        CHECK(now_continuity_grab_confirm(
                  &serving, 1, (const NowContinuityStubItem *)0)
              == kNowGrabNoSelection);
        /* THE FINDER DID NOT ANSWER, and that refuses too: "we could not
           check" is not a reason to send somebody's file. */
        CHECK(now_continuity_grab_confirm(
                  &serving, 0, (const NowContinuityStubItem *)0)
              == kNowGrabStaleSelection);
        /* Not even when a stale observation rides along with the failure. */
        CHECK(now_continuity_grab_confirm(&serving, 0, &serving)
              == kNowGrabStaleSelection);
        CHECK(now_continuity_grab_confirm(
                  (const NowContinuityStubItem *)0, 1, &serving)
              == kNowGrabNoSelection);
    }

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
    CHECK(strcmp(now_continuity_grab_code(kNowGrabGrantExpired),
                 "grant-expired") == 0);

    printf("continuity selection stub ok\n");
    return 0;
}
