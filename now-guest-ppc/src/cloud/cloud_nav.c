#include "cloud_nav.h"

#include <stdio.h>
#include <string.h>

static void copy_path(char *dst, const char *src)
{
    snprintf(dst, kCloudNavPathCap, "%s", src != NULL ? src : "");
}

/* Push onto one stack, dropping the OLDEST entry when full: the last
   kCloudNavDepth steps always win over the first ones, because Back is
   for retracing what just happened, not archaeology. */
static void push(char stack[][kCloudNavPathCap], int *count,
                 const char *path)
{
    if (*count == kCloudNavDepth) {
        memmove(stack[0], stack[1],
                (size_t)(kCloudNavDepth - 1) * kCloudNavPathCap);
        *count = kCloudNavDepth - 1;
    }
    copy_path(stack[*count], path);
    *count += 1;
}

void cloud_nav_reset(CloudNav *nav)
{
    nav->back_count = 0;
    nav->fwd_count = 0;
}

void cloud_nav_visit(CloudNav *nav, const char *from)
{
    push(nav->back, &nav->back_count, from);
    nav->fwd_count = 0;
}

static int pop_across(char from_stack[][kCloudNavPathCap], int *from_count,
                      char to_stack[][kCloudNavPathCap], int *to_count,
                      const char *current, char *out, long cap)
{
    if (*from_count == 0 || out == NULL || cap <= 0) {
        return 0;
    }
    push(to_stack, to_count, current);
    *from_count -= 1;
    snprintf(out, (size_t)cap, "%s", from_stack[*from_count]);
    return 1;
}

int cloud_nav_back(CloudNav *nav, const char *current, char *out, long cap)
{
    return pop_across(nav->back, &nav->back_count,
                      nav->fwd, &nav->fwd_count, current, out, cap);
}

int cloud_nav_forward(CloudNav *nav, const char *current,
                      char *out, long cap)
{
    return pop_across(nav->fwd, &nav->fwd_count,
                      nav->back, &nav->back_count, current, out, cap);
}

int cloud_nav_can_back(const CloudNav *nav)
{
    return nav->back_count > 0;
}

int cloud_nav_can_forward(const CloudNav *nav)
{
    return nav->fwd_count > 0;
}
