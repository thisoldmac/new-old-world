#include "cloud_preview.h"

#include <string.h>

#include "json.h"

int cloud_preview_parse_begin(const char *reply, CloudPreviewBegin *out)
{
    long min_row;

    memset(out, 0, sizeof *out);
    out->id = now_json_find_int(reply, "id", -1);
    out->transfer = now_json_find_int(reply, "transfer", 0);
    out->width = now_json_find_int(reply, "width", 0);
    out->height = now_json_find_int(reply, "height", 0);
    out->depth = now_json_find_int(reply, "depth", 0);
    out->row_bytes = now_json_find_int(reply, "rowBytes", 0);
    out->bytes = now_json_find_int(reply, "bytes", 0);

    if (out->id < 0 || out->transfer < 1 || out->transfer > 65535L) {
        return 0;
    }
    if (out->width < 1 || out->height < 1) {
        return 0;
    }
    if (out->depth != 1 && out->depth != 8) {
        return 0;
    }
    min_row = out->depth == 8 ? out->width : (out->width + 7) / 8;
    if (out->row_bytes < min_row) {
        return 0;
    }
    if (out->bytes != out->row_bytes * out->height) {
        return 0;
    }
    if (out->bytes > kCloudPreviewMaxBytes) {
        return 0;
    }
    return 1;
}

long cloud_preview_ask_depth(long screen_depth)
{
    return screen_depth >= 8 ? 8 : 1;
}

void cloud_preview_fit(long sw, long sh, long ww, long wh,
                       long *dw, long *dh)
{
    if (sw < 1 || sh < 1 || ww < 1 || wh < 1) {
        *dw = 1;
        *dh = 1;
        return;
    }
    *dw = ww;
    *dh = sh * ww / sw;
    if (*dh > wh) {
        *dh = wh;
        *dw = sw * wh / sh;
    }
    if (*dw < 1) {
        *dw = 1;
    }
    if (*dh < 1) {
        *dh = 1;
    }
}
