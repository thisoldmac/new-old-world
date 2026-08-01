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
    kWorkshopProcesses,
    kWorkshopHardware,
    kWorkshopSoftware,
    kWorkshopMCP,
    kWorkshopDiagnostics,
    kWorkshopNetworking,
    kWorkshopMirror,         /* the last nav row, above the pinned pair */
    kWorkshopLogs,
    kWorkshopConnection      /* pinned; every nav row inserted above has
                                pushed this and Logs down again, and each
                                time the prefs format moved with them -
                                Mirror takes it to 17. See now_prefs_load */
} WorkshopModuleID;

enum { kWorkshopModuleCount = 12 };

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
    /* One line for the bottom status placard. Optional; the Workshop
       falls back to a quiet default. */
    void (*status_text)(char *out, long cap);
} WorkshopModuleOps;

#endif /* NOW_WORKSHOP_MODULE_H */
