#ifndef NOW_WORKSHOP_MODULE_H
#define NOW_WORKSHOP_MODULE_H

#include <Carbon.h>

/* The contract between the Workshop window and the modules that live
   inside it. The Workshop owns the WindowRef, the placards, and event
   routing; a module owns only its child controls, its drawing state,
   and its callbacks. Modules are created lazily on first selection and
   then hidden rather than disposed, so switching away never loses
   Console history, a file listing, or capture settings. */

typedef enum {
    kWorkshopScreenshots = 1,
    kWorkshopFiles,
    kWorkshopConsole,
    kWorkshopConnection
} WorkshopModuleID;

enum { kWorkshopModuleCount = 4 };

typedef struct WorkshopModuleOps {
    OSErr (*create)(WindowRef owner, const Rect *body);
    void (*dispose)(void);
    void (*show)(Boolean visible);
    void (*layout)(const Rect *body);
    void (*draw)(void);
    Boolean (*click)(const EventRecord *event, Point local);
    Boolean (*key)(const EventRecord *event);
    void (*activate)(Boolean active);
    void (*idle)(void);
} WorkshopModuleOps;

#endif /* NOW_WORKSHOP_MODULE_H */
