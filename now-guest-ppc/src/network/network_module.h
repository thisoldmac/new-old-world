#ifndef NOW_NETWORK_MODULE_H
#define NOW_NETWORK_MODULE_H

#include "workshop_module.h"

/* Internal factory used only by this domain's static definition. Workshop
   composition consumes network_module_definition(), never this ops table. */
const WorkshopModuleOps *network_module_ops(void);
const WorkshopModuleDefinition *network_module_definition(void);

#endif /* NOW_NETWORK_MODULE_H */
