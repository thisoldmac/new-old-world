#include "control_kind.h"

#include <ControlDefinitions.h>

#include <string.h>

/* Bounded and self-evicting. Modules build and tear down their controls
   on every page switch, so this fills and wraps; a slot is claimed by
   whichever control was made most recently, and a control's own entry is
   refreshed at creation. A stale entry is never read: the scene asks
   only about controls that are in a window's list right now. */
enum { kSlots = 192 };

static struct {
    ControlRef control;
    short procID;
} g_slots[kSlots];

static int g_next;

ControlRef now_control_new(WindowRef window, const Rect *bounds,
                           ConstStr255Param title, Boolean visible,
                           short value, short min, short max,
                           short procID, long refCon)
{
    ControlRef made = NewControl(window, bounds, title, visible, value,
                                 min, max, procID, refCon);
    int i;

    if (made == NULL) {
        return NULL;
    }
    for (i = 0; i < kSlots; ++i) {
        if (g_slots[i].control == made) {
            g_slots[i].procID = procID;
            return made;
        }
    }
    g_slots[g_next].control = made;
    g_slots[g_next].procID = procID;
    g_next = (g_next + 1) % kSlots;
    return made;
}

const char *now_control_role(ControlRef control)
{
    int i;

    if (control == NULL) {
        return "";
    }
    for (i = 0; i < kSlots; ++i) {
        if (g_slots[i].control != control) {
            continue;
        }
        switch (g_slots[i].procID) {
        case pushButProc:
        case kControlPushButtonProc:
        case kControlPushButLeftIconProc:
            return "button";
        case checkBoxProc:
            return "checkbox";
        case radioButProc:
            return "radio";
        case popupMenuProc:
            return "popup";
        case scrollBarProc:
        case kControlScrollBarLiveProc:
            return "scrollbar";
        case kControlGroupBoxTextTitleProc:
            return "group";
        case kControlProgressBarProc:
            return "progress";
        case kControlTriangleAutoToggleProc:
            return "triangle";
        default:
            /* A procID nobody has mapped yet. Saying nothing leaves the
               emitter's range guess, which is worse than a name but
               better than a wrong name. */
            return "";
        }
    }
    return "";
}
