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
} NowActMenuProbe;

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
