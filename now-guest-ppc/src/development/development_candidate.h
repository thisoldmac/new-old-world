#ifndef NOW_DEVELOPMENT_CANDIDATE_H
#define NOW_DEVELOPMENT_CANDIDATE_H

#include <Carbon.h>

/* One inactive publication destination, beneath the human-selected Projects
   root and outside its active project children. Identities are opaque and HFS
   safe; callers never receive the volume or directory IDs. */
int dev_candidate_prepare(const char *candidate_id, const char *project_id,
                          FSSpec *folder, long *dir_id,
                          char *reason, long reason_cap);
int dev_candidate_folder(const char *candidate_id,
                         FSSpec *folder, long *dir_id);
int dev_candidate_accepting_folder(const char *candidate_id,
                                   FSSpec *folder, long *dir_id);
int dev_candidate_discard(const char *candidate_id,
                          char *reason, long reason_cap);

void now_development_stage_command(const char *request_json, long id,
                                   char *out, long cap);

#endif
