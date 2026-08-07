/*
 * act_menu_identity_test.c - `menuact`'s identity check, which is a
 * coordinate, checked against the machine instead of trusted.
 *
 * WHY THIS EXISTS. The resident's MenuSelect patch answers a press at
 * ONE armed point, so a press anywhere else - the person's, at the
 * machine - passes through untouched. That coordinate is therefore the
 * entire safety property of this verb, and it was earned: an act surface
 * bounded by anything weaker was measured hijacking 18 presses in 20.
 * Until 2026-08-07 nothing checked that the coordinate belonged to the
 * menu the same call named, so a caller holding a stale scene - or the
 * host's own `mirror_drive`, whose scene builder defaults an unreported
 * `left` to 0, which arms at x=4, which is the APPLE MENU - could arm on
 * one menu while naming another.
 *
 * The hijack case is the second block below, and it is exactly the state
 * a real Macintosh cannot be asked to hold still in: a menu bar saying
 * one x while a caller says another. That is why the decision lives in
 * its own translation unit and is tested here rather than only driven.
 *
 * Mutations watched failing (2026-08-07), each reverted:
 *   - `!=` -> `==` in now_act_menu_identity's comparison: the matching
 *     case reports Moved and the DISAGREEING case reports Checked, so
 *     the wrong-menu press is the one that gets armed.
 *   - drop the title_left_known guard: an unread menu bar (which zeroes
 *     the struct) reports Checked for a claimed 0 - a hijack on the
 *     Apple menu presented as a verified press.
 *   - return Checked instead of Moved on disagreement: every disagreeing
 *     press is armed, which is the pre-2026-08-07 behaviour.
 *   - make the Unchecked note read like the Checked one: the two answers
 *     stop being distinguishable by a caller, which is the whole of what
 *     publishing it buys.
 */

#include "act_menu_probe.h"

#include <stdio.h>
#include <string.h>

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        g_failures++;
    }
}

/* A menu bar that WAS read, with this menu's title at `left`. */
static NowActMenuProbe read_bar(short left)
{
    NowActMenuProbe p;

    memset(&p, 0, sizeof p);
    p.verdict = kNowActMenuProbeEnabled;
    p.title_left = left;
    p.title_left_known = 1;
    return p;
}

/* A menu bar that could not be read at all - the state the probe
   documents as "never a refusal", zeroed throughout. */
static NowActMenuProbe unread_bar(void)
{
    NowActMenuProbe p;

    memset(&p, 0, sizeof p);
    p.verdict = kNowActMenuProbeUnknown;
    return p;
}

int main(void)
{
    NowActMenuProbe    probe;
    NowActMenuIdentity id;
    long               arm;

    /* --- the caller read the same menu bar this machine has ---------- */
    probe = read_bar(214);
    arm = -1;
    id = now_act_menu_identity(&probe, 214, &arm);
    check(id == kNowActMenuIdentityChecked, "agreement is Checked");
    check(arm == 214, "the arm point is the machine's own left");

    /* --- THE HIJACK CASE --------------------------------------------
       The caller names a menu whose title this machine puts at 214 and
       describes a press at 4 - the Apple menu's x, and what a scene with
       no `left` for that menu produces. Armed, that press would answer
       whoever pressed the Apple menu next. */
    probe = read_bar(214);
    arm = -1;
    id = now_act_menu_identity(&probe, 4, &arm);
    check(id == kNowActMenuIdentityMoved, "a press elsewhere is Moved");

    /* And the stale-scene shape of the same thing: a plausible number,
       off by a few pixels, because the front application changed its
       menu bar since the caller read it. Nothing here is lenient about
       "close": a press four pixels out is a press on another title as
       readily as one two hundred out. */
    probe = read_bar(214);
    id = now_act_menu_identity(&probe, 210, NULL);
    check(id == kNowActMenuIdentityMoved, "near-misses are Moved too");
    probe = read_bar(214);
    id = now_act_menu_identity(&probe, 215, NULL);
    check(id == kNowActMenuIdentityMoved, "one pixel out is Moved");

    /* --- the machine could not be read ------------------------------
       No second opinion exists, so the caller's number is used and the
       answer says the check did not happen. The zeroed struct is the
       trap: a claimed 0 matches a zeroed title_left, and only the
       `known` flag tells a read bar whose menu sits at 0 from a bar
       nobody read. */
    probe = unread_bar();
    arm = -1;
    id = now_act_menu_identity(&probe, 4, &arm);
    check(id == kNowActMenuIdentityUnchecked, "an unread bar is Unchecked");
    check(arm == 4, "and arms where the caller said");

    probe = unread_bar();
    id = now_act_menu_identity(&probe, 0, NULL);
    check(id == kNowActMenuIdentityUnchecked,
          "a claimed 0 against a zeroed struct is still Unchecked");

    /* A bar that WAS read and really does put this menu at 0. Same two
       numbers as the case above and a different answer, which is what
       the flag is for. */
    probe = read_bar(0);
    id = now_act_menu_identity(&probe, 0, NULL);
    check(id == kNowActMenuIdentityChecked, "a real 0 is checked");

    /* --- no probe at all --------------------------------------------
       The visibility items never probe; a NULL must not read as a
       verified press. */
    arm = -1;
    id = now_act_menu_identity(NULL, 77, &arm);
    check(id == kNowActMenuIdentityUnchecked, "no probe is Unchecked");
    check(arm == 77, "and leaves the caller's number alone");

    /* --- the three answers are three sentences ----------------------
       A reply that cannot be told apart is not publishing anything. */
    check(strcmp(now_act_menu_identity_note(kNowActMenuIdentityChecked),
                 now_act_menu_identity_note(kNowActMenuIdentityUnchecked))
              != 0,
          "checked and unchecked read differently");
    check(strcmp(now_act_menu_identity_note(kNowActMenuIdentityChecked),
                 now_act_menu_identity_note(kNowActMenuIdentityMoved)) != 0,
          "checked and moved read differently");
    check(now_act_menu_identity_note(kNowActMenuIdentityUnchecked) != NULL,
          "every answer has a note");

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("act_menu_identity_test ok\n");
    return 0;
}
