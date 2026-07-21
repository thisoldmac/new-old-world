#include "confirm.h"

#include <string.h>

#include "pump.h"
#include "wire.h"

enum {
    kWidth = 340,
    kHeight = 128,
    kButtonWidth = 84,
    kButtonHeight = 20
};

static WindowRef g_window;
static ControlRef g_action, g_cancel;
static const char *g_heading;
static const char *g_detail;

static void draw(void)
{
    Rect bounds;
    Str255 text;

    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &bounds);
    EraseRect(&bounds);
    DrawControls(g_window);

    UseThemeFont(kThemeEmphasizedSystemFont, smSystemScript);
    MoveTo(20, 30);
    CopyCStringToPascal(g_heading, text);
    DrawString(text);

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    MoveTo(20, 52);
    CopyCStringToPascal(g_detail, text);
    DrawString(text);
}

Boolean now_confirm(const char *heading, const char *detail,
                    const char *action)
{
    EventRecord event;
    Rect bounds;
    Str255 text;
    Boolean done = false;
    Boolean answer = false;

    SetRect(&bounds, 100, 120, 100 + kWidth, 120 + kHeight);
    /* NO kWindowStandardHandlerAttribute. It installs HIToolbox's
       standard CARBON EVENT handler, which expects
       RunApplicationEventLoop; in this app's WaitNextEvent loop it eats
       the events instead, so the window drew its controls, never drew
       its text, and answered no clicks. An empty box with dead buttons
       and no way out - the whole app looked wedged, because a modal
       that cannot be dismissed is a wedge. */
    CreateNewWindow(kMovableModalWindowClass, kWindowNoAttributes,
                    &bounds, &g_window);
    if (g_window == NULL) {
        return false;                 /* cannot ask: do not assume yes */
    }
    g_heading = heading;
    g_detail = detail;
    CopyCStringToPascal("", text);
    SetWTitle(g_window, text);
    SetThemeWindowBackground(g_window, kThemeBrushDialogBackgroundActive,
                             true);

    SetRect(&bounds, kWidth - 16 - kButtonWidth, kHeight - 16 - kButtonHeight,
            kWidth - 16, kHeight - 16);
    CopyCStringToPascal(action, text);
    g_action = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                          pushButProc, 0);
    SetRect(&bounds, kWidth - 28 - kButtonWidth * 2,
            kHeight - 16 - kButtonHeight, kWidth - 28 - kButtonWidth,
            kHeight - 16);
    CopyCStringToPascal("Cancel", text);
    g_cancel = NewControl(g_window, &bounds, text, true, 0, 0, 1,
                          pushButProc, 0);
    ShowWindow(g_window);
    SelectWindow(g_window);
    draw();                           /* before any event, so the
                                         question is readable at once */

    while (!done) {
        /* The wire keeps running while the question waits. A person
           who steps away must not come back to a dead connection. */
        now_wire_pump();
        if (!WaitNextEvent(everyEvent, &event, 6, NULL)) {
            continue;
        }
        switch (event.what) {
        case updateEvt:
            if ((WindowRef)event.message == g_window) {
                BeginUpdate(g_window);
                draw();
                EndUpdate(g_window);
            } else {
                /* Someone else's update still has to be let through or
                   the screen behind us stays damaged. */
                BeginUpdate((WindowRef)event.message);
                EndUpdate((WindowRef)event.message);
            }
            break;
        case mouseDown: {
            WindowRef which;
            short part = FindWindow(event.where, &which);

            if (which != g_window) {
                SysBeep(1);           /* modal: everything else waits */
                break;
            }
            if (part == inDrag) {
                Rect drag;

                GetRegionBounds(GetGrayRgn(), &drag);
                DragWindow(g_window, event.where, &drag);
                break;
            }
            if (part == inContent) {
                ControlRef control = NULL;
                Point local = event.where;

                SetPortWindowPort(g_window);
                GlobalToLocal(&local);
                /* Tracking is a nested loop: with no action proc the
                   wire stops for as long as a finger rests on the
                   button. Every other tracked control here pumps. */
                if (FindControl(local, g_window, &control) != 0
                    && control != NULL
                    && TrackControl(control, local,
                                    now_pump_action()) != 0) {
                    answer = (control == g_action);
                    done = true;
                }
            }
            break;
        }
        case keyDown: {
            char c = (char)(event.message & charCodeMask);

            if (c == '\r' || c == 3) {          /* Return, Enter */
                answer = true;
                done = true;
            } else if (c == 27                  /* Escape */
                       || ((event.modifiers & cmdKey) && c == '.')
                       || ((event.modifiers & cmdKey)
                           && (c == 'q' || c == 'Q'))) {
                /* Escape, Cmd-period and Cmd-Q all mean "not this".
                   A modal with no keyboard way out is one bug away
                   from being unrecoverable. */
                answer = false;
                done = true;
            }
            break;
        }
        }
    }

    DisposeWindow(g_window);
    g_window = NULL;
    return answer;
}
