#include "pump.h"

#include "wire.h"

static ModalFilterUPP g_modal_filter;
static NavEventUPP g_nav_event;
static ControlActionUPP g_action;

static pascal Boolean pump_modal_filter(DialogRef dialog, EventRecord *event,
                                        short *item)
{
    ModalFilterUPP std_proc = NULL;

    now_wire_pump();
    /* Chain the standard filter so Return maps to the default item and
       Escape/Cmd-. to cancel; without it we would swallow the keyboard. */
    if (GetStdFilterProc(&std_proc) == noErr && std_proc != NULL) {
        return InvokeModalFilterUPP(dialog, event, item, std_proc);
    }
    return false;
}

static pascal void pump_nav_event(NavEventCallbackMessage selector,
                                  NavCBRecPtr params,
                                  NavCallBackUserData data)
{
    (void)params;
    (void)data;
    if (selector == kNavCBEvent || selector == kNavCBAdjustPreview) {
        now_wire_pump();
    }
}

static pascal void pump_action(ControlRef control, ControlPartCode part)
{
    (void)control;
    (void)part;
    now_wire_pump();
}

ModalFilterUPP now_pump_modal_filter(void)
{
    if (g_modal_filter == NULL) {
        g_modal_filter = NewModalFilterUPP(pump_modal_filter);
    }
    return g_modal_filter;
}

NavEventUPP now_pump_nav_event(void)
{
    if (g_nav_event == NULL) {
        g_nav_event = NewNavEventUPP(pump_nav_event);
    }
    return g_nav_event;
}

ControlActionUPP now_pump_action(void)
{
    if (g_action == NULL) {
        g_action = NewControlActionUPP(pump_action);
    }
    return g_action;
}

void now_pump_shutdown(void)
{
    if (g_modal_filter != NULL) {
        DisposeModalFilterUPP(g_modal_filter);
        g_modal_filter = NULL;
    }
    if (g_nav_event != NULL) {
        DisposeNavEventUPP(g_nav_event);
        g_nav_event = NULL;
    }
    if (g_action != NULL) {
        DisposeControlActionUPP(g_action);
        g_action = NULL;
    }
}
