#ifndef NOW_UPDATE_STATUS_H
#define NOW_UPDATE_STATUS_H

#include "update_model.h"

void now_update_current_identity(NowUpdateComponent component,
                                 char *version, long version_cap,
                                 char *build, long build_cap);
int now_update_extension_differs_from_app(char *line, long cap);

#endif
