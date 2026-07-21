#ifndef NOW_CONNECTION_MODULE_H
#define NOW_CONNECTION_MODULE_H

#include "workshop_module.h"

/* The Workshop's Connection page: the modeless replacement for the old
   Connection dialog. Editing and validation live here; the connection
   itself stays owned by wire.c, read through conn_snapshot(). */

const WorkshopModuleOps *connection_module_ops(void);

#endif /* NOW_CONNECTION_MODULE_H */
