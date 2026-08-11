#ifndef FILES_PATH_LABEL_H
#define FILES_PATH_LABEL_H

/* The Files page's path row: what to call the place being browsed.
   Toolbox-free on purpose - this is the half of the path row a host
   compiler can test (scripts/test-native), the way workshop_layout.c
   and conn_fields.c are split.

   `root` is file.listing's display-only root - the other machine's own
   name for its share ("iCloud Drive", "Macintosh HD:Lab:") - and may be
   empty or NULL when a host predating the field is serving. `path` is
   the wire path: colon-joined segments relative to the share root, ""
   for the root itself. The label reads as breadcrumbs from the share
   root: "iCloud Drive:Attic:Old Sites". Strings are MacRoman; the wire
   decode already projected the root through now_json_find_text. */
void now_files_path_label(const char *root, const char *path,
                          char *out, long cap);

#endif
