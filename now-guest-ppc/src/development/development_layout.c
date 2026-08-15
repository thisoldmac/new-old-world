#include "development_layout.h"

enum {
    kMargin = 12,
    kGap = 10,
    kBoxHeight = 94,
    /* One shared kButtonWidth=132 clipped the two long push-button labels
       ("Choose Projects Folder...", "Register MPW Folder...") in the
       system control font - a real Appearance Manager overflow, not a
       Toolbox limitation, since the group box has room to spare even at
       the 640x480 floor (kWorkshopMinContentW=620 minus the narrow rail
       still leaves ~440px of box width). Sized per label instead. */
    kButtonWidthProjects = 190,
    kButtonWidthToolchain = 170,
    kButtonWidthCancel = 100,
    kButtonHeight = 20
};

static void set_rect(Rect *r, short left, short top, short right, short bottom)
{
    r->left = left;
    r->top = top;
    r->right = right;
    r->bottom = bottom;
}

void development_layout_compute(const Rect *body, DevelopmentLayout *out)
{
    short left = (short)(body->left + kMargin);
    short right = (short)(body->right - kMargin);
    short top = (short)(body->top + 8);

    set_rect(&out->projects_box, left, top, right,
             (short)(top + kBoxHeight));
    set_rect(&out->projects_path, (short)(left + 14), (short)(top + 25),
             (short)(right - 14), (short)(top + 43));
    set_rect(&out->projects_choose,
             (short)(right - 14 - kButtonWidthProjects),
             (short)(top + 56), (short)(right - 14),
             (short)(top + 56 + kButtonHeight));
    top = (short)(out->projects_box.bottom + kGap);
    set_rect(&out->toolchain_box, left, top, right,
             (short)(top + kBoxHeight));
    set_rect(&out->toolchain_status, (short)(left + 14), (short)(top + 25),
             (short)(right - 14), (short)(top + 43));
    set_rect(&out->register_toolchain,
             (short)(right - 14 - kButtonWidthToolchain),
             (short)(top + 56), (short)(right - 14),
             (short)(top + 56 + kButtonHeight));
    top = (short)(out->toolchain_box.bottom + kGap);
    set_rect(&out->jobs_box, left, top, right,
             (short)(body->bottom - 8));
    set_rect(&out->jobs_status, (short)(left + 14), (short)(top + 25),
             (short)(right - 14), (short)(top + 43));
    set_rect(&out->cancel_job, (short)(right - 14 - kButtonWidthCancel),
             (short)(top + 56), (short)(right - 14),
             (short)(top + 56 + kButtonHeight));
}
