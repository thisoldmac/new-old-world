#include "control_kind.h"

#include <ControlDefinitions.h>

#include <string.h>

/* Bounded, and no longer self-evicting. It used to wrap at 192 and let a
   new control claim whichever slot came next, because the table answered
   only "what kind is this one?" and a lost answer cost a role. It is now
   the scene's LIST of controls, so a lost entry costs a control the
   mirror never mentions - and a reused slot could hand out a ControlRef
   whose control had been disposed. So: a slot is freed by disposal and by
   nothing else, and running out is reported (see
   now_control_registry_complete) rather than absorbed.

   256 against an application whose busiest window carries a few dozen
   widgets. Modules build their controls once and hide them on a page
   switch; the churn is the DataBrowsers, which are disposed and remade on
   a layout change and free their slots when they go. */
enum { kSlots = 256 };

static struct {
    ControlRef control;                /* NULL = free slot */
    WindowRef  window;
    short      procID;
} g_slots[kSlots];

static Boolean g_complete = true;

/* Bumped by every creation and every disposal. The scene compares it to
   decide whether the interface it described last time is still the one
   this application presents. */
static unsigned long g_generation;

unsigned long now_control_generation(void)
{
    return g_generation;
}

Boolean now_control_registry_complete(void)
{
    return g_complete;
}

static void remember(WindowRef window, ControlRef control, short procID)
{
    int i;

    if (control == NULL) {
        return;
    }
    ++g_generation;
    for (i = 0; i < kSlots; ++i) {
        if (g_slots[i].control == control) {
            g_slots[i].window = window;
            g_slots[i].procID = procID;
            return;
        }
    }
    for (i = 0; i < kSlots; ++i) {
        if (g_slots[i].control == NULL) {
            g_slots[i].control = control;
            g_slots[i].window = window;
            g_slots[i].procID = procID;
            return;
        }
    }
    /* Full of LIVE controls. Recording this one would mean evicting
       another that is still on screen, and the scene would then walk a
       freed ref. Drop it, and say the table is no longer the whole
       truth. */
    g_complete = false;
}

static void forget(ControlRef control)
{
    int i;

    if (control == NULL) {
        return;
    }
    for (i = 0; i < kSlots; ++i) {
        if (g_slots[i].control == control) {
            g_slots[i].control = NULL;
            g_slots[i].window = NULL;
            g_slots[i].procID = 0;
        }
    }
    ++g_generation;
}

ControlRef now_control_new(WindowRef window, const Rect *bounds,
                           ConstStr255Param title, Boolean visible,
                           short value, short min, short max,
                           short procID, long refCon)
{
    ControlRef made = NewControl(window, bounds, title, visible, value,
                                 min, max, procID, refCon);

    if (made == NULL) {
        return NULL;
    }
    remember(window, made, procID);
    return made;
}

void now_control_adopt(WindowRef window, ControlRef control, short procID)
{
    remember(window, control, procID);
}

void now_control_dispose(ControlRef control)
{
    if (control == NULL) {
        return;
    }
    /* Forget FIRST. DisposeControl can run a CDEF that pumps, and a pump
       can serve a scene request - which would walk a table still naming
       the control being freed. */
    forget(control);
    DisposeControl(control);
}

static void forget_window(WindowRef window)
{
    int i;

    if (window == NULL) {
        return;
    }
    for (i = 0; i < kSlots; ++i) {
        if (g_slots[i].window == window) {
            g_slots[i].control = NULL;
            g_slots[i].window = NULL;
            g_slots[i].procID = 0;
        }
    }
    ++g_generation;
}

void now_control_dispose_window(WindowRef window)
{
    if (window == NULL) {
        return;
    }
    forget_window(window);
    DisposeWindow(window);
}

void now_control_dispose_dialog(DialogRef dialog)
{
    if (dialog == NULL) {
        return;
    }
    forget_window(GetDialogWindow(dialog));
    DisposeDialog(dialog);
}

short now_control_count(WindowRef window)
{
    int i;
    short n = 0;

    if (window == NULL) {
        return 0;
    }
    for (i = 0; i < kSlots; ++i) {
        if (g_slots[i].control != NULL && g_slots[i].window == window) {
            ++n;
        }
    }
    return n;
}

ControlRef now_control_indexed(WindowRef window, short index)
{
    int i;
    short n = 0;

    if (window == NULL || index < 0) {
        return NULL;
    }
    for (i = 0; i < kSlots; ++i) {
        if (g_slots[i].control == NULL || g_slots[i].window != window) {
            continue;
        }
        if (n == index) {
            return g_slots[i].control;
        }
        ++n;
    }
    return NULL;
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
        case kNowControlProcDataBrowser:
            return "dataBrowser";
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
