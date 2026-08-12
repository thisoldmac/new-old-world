#ifndef NOW_CENSUS_MODULE_H
#define NOW_CENSUS_MODULE_H

#include "workshop_module.h"

/* The Hardware page: a passive census of this Mac. Probes run on request
   (never at idle); the left list is the probe registry with each probe's
   outcome, the right list the selected probe's rows. */
const WorkshopModuleOps *census_module_ops(void);
const WorkshopModuleDefinition *census_module_definition(void);

#endif /* NOW_CENSUS_MODULE_H */
