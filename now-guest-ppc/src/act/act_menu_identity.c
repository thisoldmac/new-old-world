#include "act_menu_probe.h"

/* THE IDENTITY DECISION, ALONE IN A FILE, so the host cc can compile it.
   act_menu_probe.c reaches into another process's heap and needs the
   Toolbox to do it; this decides one thing out of two numbers and needs
   nothing at all. Separating them is what lets the hijack case be
   constructed on demand - a menu bar that says one x while the caller
   says another is not a state a real Macintosh can be asked to hold
   still in, and it is the only state that matters here.

   The reasoning for the rule itself is in act_menu_probe.h, beside the
   type. */

NowActMenuIdentity now_act_menu_identity(const NowActMenuProbe *probe,
                                         long claimed, long *arm_left)
{
    if (arm_left != NULL) {
        *arm_left = claimed;
    }
    if (probe == NULL || !probe->title_left_known) {
        return kNowActMenuIdentityUnchecked;
    }
    if ((long)probe->title_left != claimed) {
        return kNowActMenuIdentityMoved;
    }
    /* Equal by now, so this changes nothing - and it is written this way
       on purpose: the machine's reading is the authority, and the
       caller's number is the thing being checked against it, never the
       other way round. */
    if (arm_left != NULL) {
        *arm_left = (long)probe->title_left;
    }
    return kNowActMenuIdentityChecked;
}

const char *now_act_menu_identity_note(NowActMenuIdentity identity)
{
    switch (identity) {
    case kNowActMenuIdentityChecked:
        return "checked: the press is where this application's own menu "
               "bar puts that menu's title";
    case kNowActMenuIdentityMoved:
        return "refused: the press is not where this application's own "
               "menu bar puts that menu's title";
    default:
        return "unchecked: this menu bar could not be read, so the press "
               "was armed where the caller said and nothing here can say "
               "that is the menu they named";
    }
}

