#ifndef NOW_WORKSHOP_SCENE_H
#define NOW_WORKSHOP_SCENE_H

/* Toolbox-free by construction: the only types crossing this seam are a
   rectangle and a boolean, so the same headers compile under the host's
   cc for the native test - the split workshop_layout.h established the
   pattern and states why the Rect field order below is exact. */
#if TARGET_API_MAC_CARBON
#include <Carbon.h>
#else
#include <stddef.h>                   /* NULL, which Carbon.h supplies */
typedef struct Rect {
    short top;
    short left;
    short bottom;
    short right;
} Rect;
typedef unsigned char Boolean;
enum { false = 0, true = 1 };
#endif

/* A small, transport-neutral description of the Workshop drawing that is
   not owned by Control Manager widgets.  The scene producer supplies the
   writer; the Workshop supplies the facts it already uses to draw itself.
   No pixels cross this seam. */
typedef enum WorkshopSceneKind {
    kWorkshopScenePanel = 1,
    kWorkshopScenePlacard,
    kWorkshopSceneSelectionBand,
    kWorkshopSceneSeparator,
    kWorkshopSceneStaticText,
    kWorkshopSceneIcon,
    kWorkshopScenePicture
} WorkshopSceneKind;

typedef struct WorkshopSceneWriter {
    void *context;
    void (*add)(void *context, WorkshopSceneKind kind, const char *title,
                const Rect *rect, Boolean enabled, Boolean visible);
} WorkshopSceneWriter;

static inline void workshop_scene_add(const WorkshopSceneWriter *writer,
                                      WorkshopSceneKind kind,
                                      const char *title, const Rect *rect,
                                      Boolean enabled)
{
    if (writer != NULL && writer->add != NULL && rect != NULL) {
        writer->add(writer->context, kind, title != NULL ? title : "",
                    rect, enabled, true);
    }
}

#endif /* NOW_WORKSHOP_SCENE_H */
