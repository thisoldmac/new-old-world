#include "act_args.h"

#include <string.h>

/* No Toolbox and no JSON here - see the header. */

int now_act_win_action(const char *name)
{
    if (name == NULL) {
        return kNowActWinUnknown;
    }
    if (strcmp(name, "move") == 0) {
        return kNowActWinMove;
    }
    if (strcmp(name, "resize") == 0) {
        return kNowActWinResize;
    }
    if (strcmp(name, "zoom") == 0) {
        return kNowActWinZoom;
    }
    if (strcmp(name, "close") == 0) {
        return kNowActWinClose;
    }
    return kNowActWinUnknown;
}

int now_act_zoom_direction(const char *name)
{
    if (name == NULL) {
        return -1;
    }
    if (strcmp(name, "out") == 0) {
        return 1;
    }
    if (strcmp(name, "in") == 0) {
        return 0;
    }
    return -1;
}

static int in_coord(long v)
{
    return v >= kNowActCoordMin && v <= kNowActCoordMax;
}

static int in_extent(long v)
{
    return v >= kNowActExtentMin && v <= kNowActCoordMax;
}

int now_act_win_args_check(const NowActWinArgs *args, const char **reason)
{
    int wants_origin;
    int wants_size;

    if (reason != NULL) {
        *reason = "";
    }
    if (args == NULL) {
        if (reason != NULL) {
            *reason = "winact takes arguments";
        }
        return 0;
    }
    if (args->action == kNowActWinUnknown) {
        if (reason != NULL) {
            *reason = "winact requires action: one of close, move, "
                      "resize, zoom";
        }
        return 0;
    }

    wants_origin = args->action == kNowActWinMove;
    wants_size = args->action == kNowActWinResize;

    /* THE KEY-SET RULE, in both directions. A missing key and a key that
       does not belong are one refusal, because they are one mistake:
       the caller sent a different request than the one it named. */
    if (wants_origin != (args->has_left && args->has_top)
        || (!wants_origin && (args->has_left || args->has_top))) {
        if (reason != NULL) {
            *reason = wants_origin
                          ? "winact with action move takes left, top"
                          : "winact with that action takes no origin; "
                            "left and top belong to move";
        }
        return 0;
    }
    if (wants_size != (args->has_width && args->has_height)
        || (!wants_size && (args->has_width || args->has_height))) {
        if (reason != NULL) {
            *reason = wants_size
                          ? "winact with action resize takes width, height"
                          : "winact with that action takes no size; width "
                            "and height belong to resize";
        }
        return 0;
    }

    if (wants_origin && (!in_coord(args->left) || !in_coord(args->top))) {
        if (reason != NULL) {
            *reason = "winact requires left and top within -32768..32767 "
                      "points, the range a QuickDraw Rect can hold";
        }
        return 0;
    }
    if (wants_size && (!in_extent(args->width) || !in_extent(args->height))) {
        if (reason != NULL) {
            *reason = "winact requires width and height of at least 1 "
                      "point and within 32767, the range a QuickDraw Rect "
                      "can hold";
        }
        return 0;
    }
    return 1;
}
