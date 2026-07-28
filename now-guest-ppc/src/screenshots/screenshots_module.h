#ifndef NOW_SCREENSHOTS_MODULE_H
#define NOW_SCREENSHOTS_MODULE_H

#include "workshop_module.h"

/* The Workshop's Screenshots page: local capture with an owned preview,
   the capture and streaming settings, and the peer actions. */

const WorkshopModuleOps *screenshots_module_ops(void);

/* The wire's running commentary on an offered screenshot
   (conn_set_shot_note). Safe before the page exists. */
void screenshots_module_note(const char *line);

#endif /* NOW_SCREENSHOTS_MODULE_H */
