#include "cloud_list_view.h"

#include <stdio.h>
#include <string.h>

/* The generic listing+card render, moved out of cloud_module.c's
   cloud_draw whole. Behaviour is unchanged. */

static void draw_at(short x, short y, const char *s)
{
    Str255 t;

    CopyCStringToPascal(s, t);
    MoveTo(x, y);
    DrawString(t);
}

static void view_draw(const CloudLayout *r, const CloudStore *store,
                      const CloudService *service, int selected)
{
    short y = (short)(r->detail_text.top + 12);
    int i;

    if (store->card_count > 0) {
        for (i = 0; i < store->card_count && y < r->detail_text.bottom;
             ++i) {
            char line[168];

            snprintf(line, sizeof line, "%.22s: %.128s",
                     store->card[i].label, store->card[i].value);
            draw_at(r->detail_text.left, y, line);
            y = (short)(y + 14);
        }
        return;
    }
    if (service != NULL
        && (strcmp(service->state, "serving") != 0
            || !cloud_service_listable(service->service))) {
        draw_at(r->detail_text.left, y, service->label);
        y = (short)(y + 16);
        if (service->detail[0] != '\0') {
            draw_at(r->detail_text.left, y, service->detail);
            y = (short)(y + 16);
        }
        if (strcmp(service->service, "drive") == 0
            && strcmp(service->state, "serving") == 0) {
            draw_at(r->detail_text.left, y,
                    "Browse it in the Files page.");
        }
        return;
    }
    if (selected < 0 && store->row_count > 0) {
        draw_at(r->detail_text.left, y, "Select an item to see its card.");
    }
}

static const CloudViewOps k_ops = {
    NULL,                              /* create */
    NULL,                              /* show */
    NULL,                              /* layout */
    view_draw,
    NULL,                              /* click: the shell's ask_save() */
    NULL,                              /* key: generic HandleControlKey */
    NULL,                              /* idle: nothing to watch */
    NULL                               /* reset_for_service: ask_rows(1) */
};

const CloudViewOps *cloud_list_view_ops(void)
{
    return &k_ops;
}
