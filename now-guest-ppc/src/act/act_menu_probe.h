#ifndef NOW_ACT_MENU_PROBE_H
#define NOW_ACT_MENU_PROBE_H

/* What the machine says about the menu item an act is about to press.
 *
 * WHY THIS EXISTS. `menuact` answers the application's own MenuSelect,
 * so the press always "succeeds": the trap returns the item and the
 * application's command handler decides what to do with it. When that
 * handler ignores the item - because the item is DISABLED - the reply
 * still read `Dispatch: dispatched`, `ok: true`, and nothing happened.
 * Watched 2026-08-07 on an emulator clone: pressing the Finder's
 * `File > Print` (disabled with nothing selected) reported exactly that,
 * and the machine did not move. A driving agent has nothing to retry on
 * and nothing to report, which is the worst failure mode this plane has.
 *
 * So the item is READ before it is pressed, out of the target process's
 * own MenuList, through the same walk the scene's menu bar comes from.
 *
 * A PROBE THAT CANNOT READ MUST NOT REFUSE. `kNowActMenuProbeUnknown`
 * is the answer whenever the menu list is unreachable - an unbound
 * process, an unarmed plane, a parse that failed - and a caller must
 * dispatch anyway and say the check was unavailable. Turning "I could
 * not look" into "no" would make this verb fail on every machine whose
 * anchors are cold, which is most of them for the first seconds after a
 * launch. Only a POSITIVE reading of absent or disabled refuses.
 */

#include <Processes.h>

#include "axmenu.h"

typedef enum {
    kNowActMenuProbeUnknown = 0,   /* could not read; dispatch anyway */
    kNowActMenuProbeNoMenu = 1,    /* no menu with that id in this bar */
    kNowActMenuProbeNoItem = 2,    /* the menu holds fewer items than that */
    kNowActMenuProbeSeparator = 3, /* the Menu Manager's "-" row */
    kNowActMenuProbeDisabled = 4,  /* present, and the app will ignore it */
    kNowActMenuProbeEnabled = 5    /* pressable */
} NowActMenuProbeVerdict;

typedef struct {
    NowActMenuProbeVerdict verdict;
    /* THE POSTCONDITION THIS ACT CAN HAVE. A menu that marks one of its
       items is a machine-stated radio group - `as Icons / as Buttons /
       as List` is one, and the checkmark moving is the Finder saying the
       view changed. When that is the shape of the menu, the act gains a
       postcondition and can reach `confirmed` instead of living forever
       at `dispatched-but-unconfirmed`. When it is not, the act stays
       unverifiable and says so rather than implying a pending answer. */
    int marked_group;              /* some item in this menu carries a mark */
    int item_marked;               /* this item carries one already */
    unsigned int item_count;       /* items walked, for the refusal text */
    char title[kNowAxTitleMax + 1];
    /* WHERE THIS MENU'S TITLE ACTUALLY SITS, out of the target's own
       MenuList - the same `NowAxMenu.left` the scene's menu bar is built
       from. It is here because the walk that reads the item passes the
       menu row on its way, so the identity check costs nothing extra;
       see now_act_menu_identity below for what it is for. Meaningful
       only where title_left_known is set: a bar that could not be read
       says nothing about where anything sits, and a zero here would
       read as "the leftmost menu". */
    short title_left;
    unsigned char title_left_known;
} NowActMenuProbe;

/* WHETHER THE PRESS THE CALLER DESCRIBED IS THE MENU THEY NAMED.
 *
 * `menuact`'s identity check is a COORDINATE (see the header comment on
 * now_act_run_menuact): the resident's MenuSelect patch answers only a
 * press at the armed point, so that a press anywhere else - the person's
 * at the machine - passes through untouched. That makes the coordinate
 * the whole of the safety property, and until 2026-08-07 nothing checked
 * that it belonged to the menu the same call named. Two ways it could be
 * wrong, both reachable without anyone doing anything careless:
 *
 *   - a STALE scene. The caller read `left` a second ago; the front
 *     application changed its menu bar since, and the number now points
 *     at a different title.
 *   - a MISSING reading. `SceneBuilder.normalizeMenus` defaults an
 *     unreported `left` to 0, and 0 arms at x=4 - which is the Apple
 *     menu. A `mirror_drive menuItem` on such a menu would arm on the
 *     Apple menu's title and answer the next press there, whoever made
 *     it. That is the measured 18/20 hijack, reintroduced by a default.
 *
 * So the machine is asked. Where the bar was readable its own `left` is
 * authoritative and a disagreement is refused; where it was not, there
 * is no second opinion to have and the act proceeds on the caller's
 * number - saying so, because an unverifiable check that reports itself
 * as a check is worse than no check at all.
 */
typedef enum {
    kNowActMenuIdentityUnchecked = 0, /* the bar could not be read */
    kNowActMenuIdentityChecked = 1,   /* the machine agrees; arm there */
    kNowActMenuIdentityMoved = 2      /* it disagrees: refuse */
} NowActMenuIdentity;

/* `claimed` is the caller's titleLeft. On any answer but Moved,
   *arm_left (when non-NULL) receives the x to arm at - the machine's own
   where it has one, the caller's where it does not. */
NowActMenuIdentity now_act_menu_identity(const NowActMenuProbe *probe,
                                         long claimed, long *arm_left);

/* The one sentence a reply carries about the check, for every answer
   including the ones that do not refuse. Never NULL. */
const char *now_act_menu_identity_note(NowActMenuIdentity identity);

/* Reads `item` of menu `menu` in `psn`'s menu bar. Never fails: an
   unreadable machine comes back as kNowActMenuProbeUnknown with the rest
   zeroed. */
void now_act_menu_probe(const ProcessSerialNumber *psn, long menu, long item,
                        NowActMenuProbe *out);

/* The wire/console error code and message for a refusing verdict, or
   NULL when the verdict does not refuse. */
const char *now_act_menu_probe_code(const NowActMenuProbe *probe);
const char *now_act_menu_probe_message(const NowActMenuProbe *probe);

#endif /* NOW_ACT_MENU_PROBE_H */
