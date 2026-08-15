#include "about_box.h"

#include <Carbon.h>
#include <stdio.h>

#include "pump.h"
#include "wire.h"
#include "control_kind.h"
#include "product_identity.h"
#include "build_stamp.h"

/* Same movable-modal shape as confirm.c (never a modal ALERT - Mac OS
   reads those aloud), reduced to one button: an About box has nothing to
   decide, only to dismiss. */

enum {
    kWidth = 300,
    kHeight = 140,
    kButtonWidth = 80,
    kButtonHeight = 20,
    kMargin = 16
};

static WindowRef g_window;
static ControlRef g_ok;
static char g_detail[128];
static char g_stamp[96];

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
    draw_wrapped(PRODUCT_DISPLAY_NAME, 14, 34);

    UseThemeFont(kThemeSmallSystemFont, smSystemScript);
    draw_wrapped(g_detail, 40, 58);
    draw_wrapped(g_stamp, 62, 92);
}

void now_about_box_show(void)
{
    EventRecord event;
    Rect bounds;
    Str255 text;
    Boolean done = false;

    snprintf(g_detail, sizeof g_detail, "Version %s",
              PRODUCT_DISPLAY_VERSION);
    snprintf(g_stamp, sizeof g_stamp, "Build %s", now_build_stamp());

    SetRect(&bounds, 120, 130, 120 + kWidth, 130 + kHeight);
    /* NO kWindowStandardHandlerAttribute - see confirm.c for why: it
       installs a Carbon Event handler that expects
       RunApplicationEventLoop and eats every event in this app's
       WaitNextEvent loop, leaving controls drawn but dead. */
    CreateNewWindow(kMovableModalWindowClass, kWindowNoAttributes,
                    &bounds, &g_window);
    if (g_window == NULL) {
        return;                        /* cannot show; nothing to undo */
    }
    CopyCStringToPascal("", text);
    SetWTitle(g_window, text);
    SetThemeWindowBackground(g_window, kThemeBrushDialogBackgroundActive,
                             true);

    SetRect(&bounds, (kWidth - kButtonWidth) / 2,
            kHeight - kMargin - kButtonHeight,
            (kWidth - kButtonWidth) / 2 + kButtonWidth,
            kHeight - kMargin);
    CopyCStringToPascal("OK", text);
    g_ok = now_control_new(g_window, &bounds, text, true, 0, 0, 1,
                           pushButProc, 0);
    if (g_ok != NULL) {
        Boolean is_default = true;

        SetControlData(g_ok, kControlEntireControl,
                       kControlPushButtonDefaultTag,
                       (Size)sizeof is_default, &is_default);
    }
    ShowWindow(g_window);
    SelectWindow(g_window);
    draw();

    while (!done) {
        /* The wire keeps running while the box is up - see confirm.c. */
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
                BeginUpdate((WindowRef)event.message);
                EndUpdate((WindowRef)event.message);
            }
            break;
        case mouseDown: {
            WindowRef which;
            short part = FindWindow(event.where, &which);

            if (which != g_window) {
                SysBeep(1);            /* modal: everything else waits */
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
                if (FindControl(local, g_window, &control) != 0
                    && control == g_ok
                    && TrackControl(control, local,
                                    now_pump_action()) != 0) {
                    done = true;
                }
            }
            break;
        }
        case keyDown: {
            char c = (char)(event.message & charCodeMask);

            if (c == '\r' || c == 3 || c == 27) {  /* Return, Enter, Esc */
                done = true;
            }
            break;
        }
        }
    }

    now_control_dispose_window(g_window);
    g_window = NULL;
}
