#include "confirm.h"

#include <string.h>

#include "pump.h"
#include "wire.h"
#include "control_kind.h"

enum {
    kWidth = 340,
    kHeight = 156,
    kButtonWidth = 116,
    kButtonHeight = 20,
    kMargin = 16
};

static WindowRef g_window;
static ControlRef g_action, g_cancel;
static const char *g_heading;
static const char *g_detail;

/* Both strings were drawn with a single MoveTo/DrawString, which does not
   wrap: the detail line is built from a peer name plus a fixed sentence
   and runs past 300 pixels for any ordinary machine name, so the end of
   the sentence - the part that says the old file goes to the Trash - was
   simply off the edge of the window. A question whose consequence is
   clipped is not a question.

   TETextBox wraps inside a rect using the port's current font, so it
   composes with UseThemeFont and needs no measuring here. */
static void draw_wrapped(const char *s, short top, short bottom)
{
    Str255 text;
    Rect box;

    if (s == NULL || s[0] == '\0') {
        return;
    }
    CopyCStringToPascal(s, text);
    SetRect(&box, kMargin, top, kWidth - kMargin, bottom);
    TETextBox(text + 1, (SInt32)text[0], &box, teJustLeft);
}

static void draw(void)
{
    Rect bounds;

    SetPortWindowPort(g_window);
    GetWindowPortBounds(g_window, &bounds);
    EraseRect(&bounds);
    DrawControls(g_window);

    UseThemeFont(kThemeEmphasizedSystemFont, smSystemScript);
    draw_wrapped(g_heading, 14, 50);

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    draw_wrapped(g_detail, 56, 108);
}

NowChoice now_choose(const char *heading, const char *detail,
                     const char *action, const char *alternative)
{
    EventRecord event;
    Rect bounds;
    Str255 text;
    Boolean done = false;
    NowChoice answer = kNowChoiceDismissed;

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
        return kNowChoiceDismissed;   /* cannot ask: do not assume yes */
    }
    g_heading = heading;
    g_detail = detail;
    CopyCStringToPascal("", text);
    SetWTitle(g_window, text);
    SetThemeWindowBackground(g_window, kThemeBrushDialogBackgroundActive,
                             true);

    SetRect(&bounds, kWidth - kMargin - kButtonWidth,
            kHeight - kMargin - kButtonHeight, kWidth - kMargin,
            kHeight - kMargin);
    CopyCStringToPascal(action, text);
    g_action = now_control_new(g_window, &bounds, text, true, 0, 0, 1,
                          pushButProc, 0);
    /* Return already chose this button; nothing SAID so. The default ring
       is the only thing that tells a person which key commits, and its
       absence is why this dialog read as "two equal buttons, pick one".
       The 12 px between the two base rects is the HIG figure and excludes
       the ring, which is drawn outside by the CDEF. */
    if (g_action != NULL) {
        Boolean is_default = true;

        SetControlData(g_action, kControlEntireControl,
                       kControlPushButtonDefaultTag,
                       (Size)sizeof is_default, &is_default);
    }
    SetRect(&bounds, kWidth - kMargin - 12 - kButtonWidth * 2,
            kHeight - kMargin - kButtonHeight,
            kWidth - kMargin - 12 - kButtonWidth, kHeight - kMargin);
    CopyCStringToPascal(alternative, text);
    g_cancel = now_control_new(g_window, &bounds, text, true, 0, 0, 1,
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
                    answer = control == g_action
                        ? kNowChoiceAction : kNowChoiceAlternative;
                    done = true;
                }
            }
            break;
        }
        case keyDown: {
            char c = (char)(event.message & charCodeMask);

            if (c == '\r' || c == 3) {          /* Return, Enter */
                answer = kNowChoiceAction;
                done = true;
            } else if (c == 27                  /* Escape */
                       || ((event.modifiers & cmdKey) && c == '.')
                       || ((event.modifiers & cmdKey)
                           && (c == 'q' || c == 'Q'))) {
                /* Escape, Cmd-period and Cmd-Q all mean "not this".
                   A modal with no keyboard way out is one bug away
                   from being unrecoverable. */
                answer = kNowChoiceDismissed;
                done = true;
            }
            break;
        }
        }
    }

    now_control_dispose_window(g_window);
    g_window = NULL;
    return answer;
}

Boolean now_confirm(const char *heading, const char *detail,
                    const char *action)
{
    return now_choose(heading, detail, action, "Cancel")
        == kNowChoiceAction;
}
