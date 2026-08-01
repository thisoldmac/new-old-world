#include "files_path_label.h"

#include <stdio.h>
#include <string.h>

void now_files_path_label(const char *root, const char *path,
                          char *out, long cap)
{
    const char *label = (root != NULL && root[0] != '\0')
        ? root : "Shared folder";

    if (out == NULL || cap <= 0) {
        return;
    }
    if (path == NULL || path[0] == '\0') {
        snprintf(out, (size_t)cap, "%s", label);
        return;
    }
    /* A classic-side root already ends with its own separator
       ("Macintosh HD:Lab:"); a display name does not. One colon between
       the root and the path, never zero and never two. */
    if (label[strlen(label) - 1] == ':') {
        snprintf(out, (size_t)cap, "%s%s", label, path);
    } else {
        snprintf(out, (size_t)cap, "%s:%s", label, path);
    }
}
