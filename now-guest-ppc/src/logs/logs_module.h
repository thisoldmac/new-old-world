#ifndef NOW_LOGS_MODULE_H
#define NOW_LOGS_MODULE_H

#include "workshop_module.h"

/* The Workshop's Logs page: a scrolling dump of this launch's in-memory
   log ring (nowlog.c), Monaco so the timestamps line up, with a switch
   for whether each line also reaches the now-logs file on disk. Read-only
   - the events come from every other subsystem, not from here. */

const WorkshopModuleOps *logs_module_ops(void);
const WorkshopModuleDefinition *logs_module_definition(void);

#endif /* NOW_LOGS_MODULE_H */
