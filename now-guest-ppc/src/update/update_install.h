#ifndef NOW_UPDATE_INSTALL_H
#define NOW_UPDATE_INSTALL_H

#include <Carbon.h>

#include "update_model.h"

int now_update_destination(NowUpdateComponent component,
                           short *vref, long *dir, const char **leaf,
                           char *reason, long cap);
int now_update_install(NowUpdateComponent component, const FSSpec *staged,
                       char *reason, long cap);

#endif
