#ifndef NOW_SOFTWARE_MODULE_H
#define NOW_SOFTWARE_MODULE_H

#include "workshop_module.h"

/* The Software page: what is installed on this Mac, and starting it. The
   split-view sibling of Processes, built on the data layer in software.h
   and the pure geometry in software_layout.h. */

const WorkshopModuleOps *software_module_ops(void);

#endif /* NOW_SOFTWARE_MODULE_H */
