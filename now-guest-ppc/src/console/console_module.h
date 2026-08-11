#ifndef NOW_CONSOLE_MODULE_H
#define NOW_CONSOLE_MODULE_H

#include "workshop_module.h"

/* The Workshop's Console page: white Monaco scrollback over
   console_model.c, a native input field and Run button, and the
   persisted Invert switch on the status placard. */

const WorkshopModuleOps *console_module_ops(void);

#endif /* NOW_CONSOLE_MODULE_H */
