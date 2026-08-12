#ifndef NOW_FILES_MODULE_H
#define NOW_FILES_MODULE_H

#include "workshop_module.h"

/* The Workshop's Files page: the peer's share on top (browser view),
   what this Mac exposes below a disclosure (share view), one status
   line between them. */

const WorkshopModuleOps *files_module_ops(void);
const WorkshopModuleDefinition *files_module_definition(void);

#endif /* NOW_FILES_MODULE_H */
