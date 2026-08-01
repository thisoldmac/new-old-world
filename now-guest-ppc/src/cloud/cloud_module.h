#ifndef NOW_CLOUD_MODULE_H
#define NOW_CLOUD_MODULE_H

#include "fileshare.h"
#include "workshop_module.h"

const WorkshopModuleOps *cloud_module_ops(void);

/* The drive browser's listing consumer (conn_set_listing). The hook
   follows whoever asked last; this page and the Files page each
   reclaim it when they ask. */
void cloud_drive_listing(const char *path, const FileEntry *entries,
                         int count, Boolean more, long cursor,
                         const char *root, const char *error);

#endif /* NOW_CLOUD_MODULE_H */
