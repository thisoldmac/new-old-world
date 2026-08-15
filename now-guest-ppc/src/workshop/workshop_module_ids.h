#ifndef NOW_WORKSHOP_MODULE_IDS_H
#define NOW_WORKSHOP_MODULE_IDS_H

/* The page identities alone, free of every Toolbox header, so the files
   that only need to know WHICH page a number means can be compiled by
   the host's cc for a native test - the split workshop_layout.h already
   makes for the rectangles. workshop_module.h includes this and adds the
   Carbon-dependent half; nothing should include both. */

typedef enum {
    kWorkshopScreenshots = 1,
    kWorkshopFiles = 2,
    kWorkshopConsole = 3,
    kWorkshopProcesses = 4,
    kWorkshopHardware = 5,
    kWorkshopSoftware = 6,
    kWorkshopMCP = 7,
    kWorkshopDiagnostics = 8,
    kWorkshopNetworking = 9,
    kWorkshopCloud = 10,
    kWorkshopChat = 11,
    kWorkshopMirror = 12,    /* the last nav row, above the pinned group */
    kWorkshopDevelopment = 13,
    kWorkshopWeb = 14,

    /* The pinned group, in the order it sits at the foot of the rail.
       These three are NOT in the person's rearrangeable order: the rail
       is theirs to arrange above the divider, and the utilities below it
       stay where they are put. */
    kWorkshopPreferences = 15,
    kWorkshopLogs = 16,
    kWorkshopConnection = 17 /* pinned; every nav insertion pushes this
                                and Logs down — iCloud moved the prefs
                                format to 17, Chat to 18, the Preferences
                                page to 19, Mirror to 21 (20 was the
                                rail's collapsed state, which renumbered
                                nothing), Development to 23 and Web to 24;
                                see now_prefs_load */
} WorkshopModuleID;

enum { kWorkshopModuleCount = 17 };

/* The nav range is a CONTIGUOUS prefix, 1..kWorkshopNavRows, and the
   pinned group is everything after it. The sidebar's saved order stores
   ids from this range, so the range must stay a prefix: a new page goes
   in before Preferences (extending the nav range) or after Connection,
   never in between. */
#define kWorkshopIsNavModule(m) \
    ((int)(m) >= 1 && (int)(m) < (int)kWorkshopPreferences)

#endif /* NOW_WORKSHOP_MODULE_IDS_H */
