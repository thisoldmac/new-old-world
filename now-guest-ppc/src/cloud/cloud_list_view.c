#include "cloud_list_view.h"

#include <stdio.h>
#include <string.h>

#include "cloud_filter.h"

/* The generic listing+card render, moved out of cloud_module.c's
   cloud_draw whole. Behaviour is unchanged. */

/* One line of hand-drawn text, drawn or described — cloud_module.c's
   emit_at, the same idiom, kept local rather than shared because this
   file's rect is always the pane's own right edge, never a caller's. */
static void emit_line(const WorkshopSceneWriter *writer,
                      const CloudLayout *r, short x, short y,
                      const char *s)
{
    if (writer != NULL) {
        Rect where;

        SetRect(&where, x, (short)(y - 11), r->detail_text.right,
               (short)(y + 3));
        workshop_scene_add(writer, kWorkshopSceneStaticText, s, &where,
                           true);
        return;
    }
    {
        Str255 t;

        CopyCStringToPascal(s, t);
        MoveTo(x, y);
        DrawString(t);
    }
}

static void view_content(const WorkshopSceneWriter *writer,
                         const CloudLayout *r, const CloudStore *store,
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
            emit_line(writer, r, r->detail_text.left, y, line);
            y = (short)(y + 14);
        }
        return;
    }
    if (service != NULL
        && (strcmp(service->state, "serving") != 0
            || !cloud_service_listable(service->service))) {
        emit_line(writer, r, r->detail_text.left, y, service->label);
        y = (short)(y + 16);
        if (service->detail[0] != '\0') {
            emit_line(writer, r, r->detail_text.left, y, service->detail);
            y = (short)(y + 16);
        }
        if (strcmp(service->service, "drive") == 0
            && strcmp(service->state, "serving") == 0) {
            emit_line(writer, r, r->detail_text.left, y,
                     "Browse it in the Files page.");
        }
        return;
    }
    if (selected < 0 && store->row_count > 0) {
        emit_line(writer, r, r->detail_text.left, y,
                 "Select an item to see its card.");
    }
}

static void view_draw(const CloudLayout *r, const CloudStore *store,
                      const CloudService *service, int selected)
{
    view_content(NULL, r, store, service, selected);
}

static void view_describe(const WorkshopSceneWriter *writer,
                          const CloudLayout *r, const CloudStore *store,
                          const CloudService *service, int selected)
{
    view_content(writer, r, store, service, selected);
}

/* The shell's shared rows (CloudRow), searched by title and subtitle —
   the two fields the Data Browser's own columns already show, so a
   match is never a surprise once someone reads the row it kept. */
static Boolean view_row_matches(int index, const CloudStore *store,
                                const char *needle)
{
    const CloudRow *row;

    if (store == NULL || index < 0 || index >= store->row_count) {
        return false;
    }
    row = &store->rows[index];
    return cloud_filter_matches_either(row->title, row->subtitle, needle);
}

static const CloudViewOps k_ops = {
    NULL,                              /* create */
    NULL,                              /* show */
    NULL,                              /* layout */
    view_draw,
    view_describe,
    NULL,                              /* click: the shell's ask_save() */
    NULL,                              /* key: generic HandleControlKey */
    NULL,                              /* idle: nothing to watch */
    NULL,                              /* reset_for_service: ask_rows(1) */
    view_row_matches,
    NULL,                              /* select: the card is the state */
    NULL,                              /* control_click: no own controls */
    NULL                               /* save_size: host default */
};

const CloudViewOps *cloud_list_view_ops(void)
{
    return &k_ops;
}

void cloud_list_view_draw_card(const CloudLayout *r,
                               const CloudStore *store,
                               const CloudService *service, int selected)
{
    view_content(NULL, r, store, service, selected);
}

void cloud_list_view_describe_card(const WorkshopSceneWriter *writer,
                                   const CloudLayout *r,
                                   const CloudStore *store,
                                   const CloudService *service,
                                   int selected)
{
    view_content(writer, r, store, service, selected);
}
