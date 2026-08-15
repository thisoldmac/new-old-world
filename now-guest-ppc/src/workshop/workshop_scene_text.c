#include "workshop_scene_text.h"

#include <string.h>

/* Two runs whose rects start within this many pixels of each other were
   drawn on the same line - a label and its value, a probe name and its
   verb - so they are joined rather than broken apart. The Workshop's
   pages use 12 to 17 pixel line heights, so half a line is a safe
   discriminator and does not need to know which page it is reading. */
enum { kSameLineSlop = 6 };

static void append(WorkshopSceneText *sink, const char *s)
{
    long n;

    if (sink->cap <= 1) {
        return;
    }
    n = (long)strlen(s);
    if (sink->len + n > sink->cap - 1) {
        n = sink->cap - 1 - sink->len;   /* truncate, never overrun */
    }
    if (n <= 0) {
        return;
    }
    memcpy(sink->out + sink->len, s, (size_t)n);
    sink->len += n;
    sink->out[sink->len] = '\0';
}

static void scene_text_add(void *context, WorkshopSceneKind kind,
                           const char *title, const Rect *rect,
                           Boolean enabled, Boolean visible)
{
    WorkshopSceneText *sink = (WorkshopSceneText *)context;

    (void)enabled;
    if (sink == NULL || !visible || title == NULL || title[0] == '\0') {
        return;
    }
    /* Only words. A panel, a selection band or an icon describes a
       region, and a region copied as text is a blank line. */
    if (kind != kWorkshopSceneStaticText && kind != kWorkshopScenePlacard) {
        return;
    }
    if (sink->any) {
        short dy = (short)(rect->top - sink->last_top);

        if (dy < 0) {
            dy = (short)-dy;
        }
        append(sink, dy <= kSameLineSlop ? "  " : "\r");
    }
    append(sink, title);
    sink->last_top = rect->top;
    sink->any = true;
}

void workshop_scene_text_begin(WorkshopSceneText *sink,
                               WorkshopSceneWriter *writer, char *out,
                               long cap)
{
    sink->out = out;
    sink->cap = cap;
    sink->len = 0;
    sink->last_top = 0;
    sink->any = false;
    if (cap > 0) {
        out[0] = '\0';
    }
    writer->context = sink;
    writer->add = scene_text_add;
}

long workshop_scene_text_end(WorkshopSceneText *sink)
{
    return sink->len;
}
