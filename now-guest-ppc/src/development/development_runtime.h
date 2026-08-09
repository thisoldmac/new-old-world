#ifndef NOW_DEVELOPMENT_RUNTIME_H
#define NOW_DEVELOPMENT_RUNTIME_H

void now_development_build_command(const char *request_json, long id,
                                   char *out, long cap);
void now_development_run_command(const char *request_json, long id,
                                 char *out, long cap);
void now_development_open_command(const char *request_json, long id,
                                  char *out, long cap);
void now_development_runtime_idle(void);
void now_development_runtime_cancel(void);
int now_development_runtime_active(void);
void now_development_runtime_status(char *out, long cap);

#endif
