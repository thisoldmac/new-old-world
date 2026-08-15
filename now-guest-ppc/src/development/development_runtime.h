#ifndef NOW_DEVELOPMENT_RUNTIME_H
#define NOW_DEVELOPMENT_RUNTIME_H

#include "development_history.h"
#include "development_projects_rows.h"

void now_development_build_command(const char *request_json, long id,
                                   char *out, long cap);
void now_development_run_command(const char *request_json, long id,
                                 char *out, long cap);
void now_development_test_command(const char *request_json, long id,
                                  char *out, long cap);
void now_development_open_command(const char *request_json, long id,
                                  char *out, long cap);
void now_development_runtime_idle(void);
void now_development_runtime_cancel(void);
int now_development_runtime_active(void);
void now_development_runtime_status(char *out, long cap);

/* The opaque reference the last successful build produced, or empty when
   there is none or it is no longer exact. The page gates Run on it. */
void now_development_runtime_product(char *out, long cap);

/* The last few settled builds, newest first, for the page to draw.
   Deliberately not on the wire: the host watches each job settle as it
   drives it, so this is a renderer for something the wire already saw -
   the same shape as NOW-68K's console-only `xfer`. The person at the
   machine is the one with no other record. */
const DevJobHistory *now_development_runtime_history(void);

#endif
