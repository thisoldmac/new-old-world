#include "screen_bounds.h"

/* What the menu bar takes off the top of a raw device rect. GetGrayRgn()
 * has already removed it; this is only for the path where GetGrayRgn()
 * would not answer. GetMBarHeight() is the exact figure, and it is asked
 * for rather than assumed - a rooted menu bar is not always 20 pixels. */
static short menu_bar_allowance(void)
{
    short h = GetMBarHeight();

    return h > 0 ? h : 0;
}

void now_screen_size(short *w, short *h)
{
    GDHandle device = GetMainDevice();

    *w = 0;
    *h = 0;
    if (device != NULL) {
        Rect r = (**device).gdRect;

        *w = (short)(r.right - r.left);
        *h = (short)(r.bottom - r.top);
    }
}

void now_screen_desktop(Rect *out)
{
    RgnHandle desktop = GetGrayRgn();
    GDHandle device;

    SetRect(out, 0, 0, 0, 0);
    if (desktop != NULL) {
        GetRegionBounds(desktop, out);
        if (out->right > out->left && out->bottom > out->top) {
            return;
        }
    }
    /* MEASURE AGAIN rather than name a size. A missing desktop region is
     * not a screen we know; it is a reason to ask the other thing that
     * knows. The literals that used to sit here (0, 20, 800, 600) were a
     * fifth opinion about this machine, in the one place nobody would
     * ever watch it be wrong. */
    device = GetMainDevice();
    if (device != NULL) {
        *out = (**device).gdRect;
        out->top = (short)(out->top + menu_bar_allowance());
        return;
    }
    SetRect(out, 0, 0, 0, 0);   /* unknown, and it says so */
}
