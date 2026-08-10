#include "development_layout.h"

#include <assert.h>

int main(void)
{
    Rect body = { 40, 160, 440, 740 };
    DevelopmentLayout out;

    development_layout_compute(&body, &out);
    assert(out.projects_box.left >= body.left);
    assert(out.projects_choose.right <= body.right);
    assert(out.toolchain_box.top >= out.projects_box.bottom);
    assert(out.register_toolchain.right <= body.right);
    assert(out.jobs_box.top >= out.toolchain_box.bottom);
    assert(out.cancel_job.bottom <= body.bottom);
    return 0;
}
