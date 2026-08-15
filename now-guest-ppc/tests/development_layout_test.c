#include "development_layout.h"

#include <assert.h>

static int inside(const Rect *r, const Rect *body)
{
    return r->left >= body->left && r->right <= body->right
        && r->top >= body->top && r->bottom <= body->bottom
        && r->right > r->left && r->bottom > r->top;
}

static void check(const Rect *body)
{
    DevelopmentLayout out;
    int i;

    development_layout_compute(body, &out);
    assert(inside(&out.list, body));
    assert(inside(&out.projects_choose, body));
    assert(inside(&out.detail, body));
    assert(inside(&out.title_line, body));
    assert(inside(&out.product_line, body));
    assert(inside(&out.toolchain_status, body));
    assert(inside(&out.register_toolchain, body));
    assert(inside(&out.build_btn, body));
    assert(inside(&out.run_btn, body));
    assert(inside(&out.jobs_box, body));
    assert(inside(&out.jobs_status, body));
    assert(inside(&out.cancel_job, body));

    /* The two columns never overlap, and neither reaches into the jobs
       strip pinned at the foot. */
    assert(out.list.right < out.detail.left);
    assert(out.list.bottom <= out.projects_choose.top);
    assert(out.projects_choose.bottom <= out.jobs_box.top);
    assert(out.detail.bottom <= out.jobs_box.top);
    assert(out.build_btn.right < out.run_btn.left);
    assert(out.run_btn.right <= body->right);

    /* The facts stack in reading order without colliding with the
       controls beneath them. */
    assert(out.title_line.bottom <= out.id_line.top);
    assert(out.id_line.bottom <= out.target_line.top);
    assert(out.target_line.bottom <= out.configuration_line.top);
    assert(out.configuration_line.bottom <= out.toolchain_pin_line.top);
    assert(out.toolchain_pin_line.bottom <= out.product_line.top);
    assert(out.product_line.bottom <= out.toolchain_status.top);
    assert(out.toolchain_status.bottom <= out.register_toolchain.top);
    assert(out.register_toolchain.bottom <= out.build_btn.top);

    /* Every history row fits inside the box and stops short of Cancel,
       which is what keeps a long project name off the button. */
    for (i = 0; i < kDevJobRowsShown; ++i) {
        assert(inside(&out.job_rows[i], &out.jobs_box));
        assert(out.job_rows[i].right <= out.cancel_job.left);
        assert(out.job_rows[i].top >= out.jobs_status.bottom);
        if (i > 0) {
            assert(out.job_rows[i].top >= out.job_rows[i - 1].bottom);
        }
    }
}

int main(void)
{
    /* The standard window... */
    Rect wide = { 40, 160, 440, 740 };
    /* ...and the 640x480 floor: a 620-wide window with the narrow rail
       leaves this body, which is the case the page has to survive. */
    Rect minimum = { 38, 128, 421, 620 };
    DevelopmentLayout narrow;
    DevelopmentLayout roomy;

    check(&wide);
    check(&minimum);

    development_layout_compute(&minimum, &narrow);
    development_layout_compute(&wide, &roomy);
    /* The list gives up width first when the body narrows, so the
       detail column keeps room for a toolchain pin. */
    assert(narrow.list.right - narrow.list.left
           < roomy.list.right - roomy.list.left);
    assert(narrow.detail.right - narrow.detail.left >= 180);
    return 0;
}
