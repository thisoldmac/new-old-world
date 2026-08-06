#ifndef NOW_WORKSHOP_MODULE_H
#define NOW_WORKSHOP_MODULE_H

#include <Carbon.h>
#include "workshop_scene.h"

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
    kWorkshopCloud,
    kWorkshopChat,
    kWorkshopMirror,         /* the last nav row, above the pinned group */

    /* The pinned group, in the order it sits at the foot of the rail.
       These three are NOT in the person's rearrangeable order: the rail
       is theirs to arrange above the divider, and the utilities below it
       stay where they are put. */
    kWorkshopPreferences,
    kWorkshopLogs,
    kWorkshopConnection      /* pinned; every nav insertion pushes this
                                and Logs down — iCloud moved the prefs
                                format to 17, Chat to 18, the Preferences
                                page to 19, and Mirror to 21 (20 was the
                                rail's collapsed state, which renumbered
                                nothing); see now_prefs_load */
} WorkshopModuleID;

enum { kWorkshopModuleCount = 15 };

/* The nav range is a CONTIGUOUS prefix, 1..kWorkshopNavRows, and the
   pinned group is everything after it. The sidebar's saved order stores
   ids from this range, so the range must stay a prefix: a new page goes
   in before Preferences (extending the nav range) or after Connection,
   never in between. */
#define kWorkshopIsNavModule(m) \
    ((int)(m) >= 1 && (int)(m) < (int)kWorkshopPreferences)

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
    /* Semantic content the module draws by hand. Optional; child controls
       remain Control Manager facts and must not be repeated here. */
    void (*describe_scene)(const WorkshopSceneWriter *writer);
} WorkshopModuleOps;

#endif /* NOW_WORKSHOP_MODULE_H */
