#include "scene_theme.h"

#include <Appearance.h>
#include <Quickdraw.h>

/* An RGBColor is 16 bits per channel; the wire and every renderer this
   feeds are 8. `>> 8` rather than a scale-and-round because the Toolbox
   replicates the byte (0xDD becomes 0xDDDD), so the high byte IS the
   original value and any arithmetic on it would only move it. */
static long rgb24(const RGBColor *c)
{
    return (((long)(c->red >> 8) & 0xFF) << 16)
         | (((long)(c->green >> 8) & 0xFF) << 8)
         | ((long)(c->blue >> 8) & 0xFF);
}

/* The screen's real depth, because a brush answers differently at 8 bits
   than at 32 and the answer is meant to be checkable against a
   screendump of that same screen. The guest's other callers pass a flat
   32 (census_module.c), which is right for what they draw with and wrong
   for what this reports. 0 means the device would not say. */
static short main_depth(void)
{
    GDHandle device = GetMainDevice();
    PixMapHandle pm;

    if (device == NULL) {
        return 0;
    }
    pm = (**device).gdPMap;
    if (pm == NULL) {
        return 0;
    }
    return (**pm).pixelSize;
}

static long ask_brush(ThemeBrush brush, short depth)
{
    RGBColor c;

    c.red = 0;
    c.green = 0;
    c.blue = 0;
    /* A REFUSAL IS A -1, NOT A BLACK. The zeroing above is what makes
       that honest: without it a failing call would leave the stack's
       last colour behind and it would ride the wire as measured. */
    if (GetThemeBrushAsColor(brush, depth, true, &c) != noErr) {
        return -1;
    }
    return rgb24(&c);
}

void now_scene_theme_ask(NowSceneTheme *out)
{
    RGBColor hilite;
    short depth;

    if (out == NULL) {
        return;
    }
    out->dialog_background = -1;
    out->alert_background = -1;
    out->document_background = -1;
    out->highlight = -1;
    out->depth = -1;

    depth = main_depth();
    if (depth <= 0) {
        /* No device to ask at. Falling back to 32 would publish a colour
           for a screen nobody measured; leaving every field -1 says the
           machine was not asked, which is what happened. */
        return;
    }
    out->depth = depth;

    /* THE THREE BRUSHES ARE CarbonLib 1.0 (Appearance.h, first enum) -
       below the 1.6 floor, so no Gestalt gate. `Inactive` variants are
       deliberately absent: the scene has no per-window active bit that a
       renderer could key them off, and a field with no consumer is a
       field nobody notices going wrong. */
    out->dialog_background = ask_brush(kThemeBrushDialogBackgroundActive,
                                       depth);
    out->alert_background = ask_brush(kThemeBrushAlertBackgroundActive,
                                      depth);
    out->document_background = ask_brush(kThemeBrushDocumentWindowBackground,
                                         depth);

    /* Not a brush: the selection fill is a low-memory colour, and the
       Appearance Manager keeps it in step with the theme. CarbonLib 1.0
       (Quickdraw.h). It returns void, so there is no refusal to catch -
       the value at 0x0DA0 is always readable, whatever it holds. */
    hilite.red = 0;
    hilite.green = 0;
    hilite.blue = 0;
    LMGetHiliteRGB(&hilite);
    out->highlight = rgb24(&hilite);
}
