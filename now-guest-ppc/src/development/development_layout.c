#include "development_layout.h"

static void set_rect(Rect *r, short left, short top, short right, short bottom)
{
    r->left = left;
    r->top = top;
    r->right = right;
    r->bottom = bottom;
}

void development_layout_compute(const Rect *body, DevelopmentLayout *out)
{
    short left = (short)(body->left + kDevMargin);
    short right = (short)(body->right - kDevMargin);
    short top = (short)(body->top + 8);
    short width = (short)(body->right - body->left);
    short list_w = (short)(width < kDevListNarrowBelow ? kDevListNarrow
                                                       : kDevListWide);
    short panes_bottom;
    short detail_left;
    short detail_inner;
    short y;
    int i;

    /* The jobs strip pins to the foot, so a short window squeezes the
       list and the facts rather than pushing the controls off. */
    set_rect(&out->jobs_box, left,
             (short)(body->bottom - 8 - kDevJobsBoxHeight),
             right, (short)(body->bottom - 8));
    panes_bottom = (short)(out->jobs_box.top - kDevPaneGap);

    set_rect(&out->projects_choose, left,
             (short)(panes_bottom - kDevButtonHeight),
             (short)(left + kDevButtonWidthProjects), panes_bottom);
    set_rect(&out->list, left, top, (short)(left + list_w),
             (short)(out->projects_choose.top - 6));

    detail_left = (short)(out->list.right + kDevPaneGap);
    set_rect(&out->detail, detail_left, top, right, panes_bottom);
    detail_inner = (short)(detail_left + 2);

    y = top;
    set_rect(&out->title_line, detail_inner, y, right,
             (short)(y + kDevTitleHeight));
    y = (short)(out->title_line.bottom + 2);
    set_rect(&out->id_line, detail_inner, y, right,
             (short)(y + kDevLineHeight));
    y = out->id_line.bottom;
    set_rect(&out->target_line, detail_inner, y, right,
             (short)(y + kDevLineHeight));
    y = out->target_line.bottom;
    set_rect(&out->configuration_line, detail_inner, y, right,
             (short)(y + kDevLineHeight));
    y = out->configuration_line.bottom;
    set_rect(&out->toolchain_pin_line, detail_inner, y, right,
             (short)(y + kDevLineHeight));
    y = out->toolchain_pin_line.bottom;
    set_rect(&out->product_line, detail_inner, y, right,
             (short)(y + kDevLineHeight));

    /* Build and Run act on the SELECTED project and sit at the foot of
       its pane, level with the list's own button. */
    set_rect(&out->build_btn, detail_inner,
             (short)(panes_bottom - kDevButtonHeight),
             (short)(detail_inner + kDevButtonWidthBuild), panes_bottom);
    set_rect(&out->run_btn, (short)(out->build_btn.right + 8),
             out->build_btn.top,
             (short)(out->build_btn.right + 8 + kDevButtonWidthRun),
             panes_bottom);

    /* Registering MPW is about the MACHINE, not the selection, so it
       keeps its own row above the two project actions. */
    set_rect(&out->register_toolchain,
             (short)(right - kDevButtonWidthToolchain),
             (short)(out->build_btn.top - 6 - kDevButtonHeight), right,
             (short)(out->build_btn.top - 6));
    set_rect(&out->toolchain_status, detail_inner,
             (short)(out->register_toolchain.top - kDevLineHeight - 2),
             right, (short)(out->register_toolchain.top - 2));

    set_rect(&out->cancel_job,
             (short)(out->jobs_box.right - 14 - kDevButtonWidthCancel),
             (short)(out->jobs_box.top + 34),
             (short)(out->jobs_box.right - 14),
             (short)(out->jobs_box.top + 34 + kDevButtonHeight));
    set_rect(&out->jobs_status, (short)(out->jobs_box.left + 14),
             (short)(out->jobs_box.top + 14),
             (short)(out->jobs_box.right - 14),
             (short)(out->jobs_box.top + 14 + kDevLineHeight));
    y = (short)(out->jobs_status.bottom + 2);
    for (i = 0; i < kDevJobRowsShown; ++i) {
        set_rect(&out->job_rows[i], (short)(out->jobs_box.left + 14), y,
                 (short)(out->cancel_job.left - 8),
                 (short)(y + kDevLineHeight));
        y = (short)(y + kDevLineHeight);
    }
}
