#ifndef NOW_WEB_PROXY_OT_H
#define NOW_WEB_PROXY_OT_H

#include <Carbon.h>

int now_web_proxy_start(unsigned short port, char *reason, long cap);
void now_web_proxy_stop(void);
void now_web_proxy_service(void);
Boolean now_web_proxy_is_running(void);
Boolean now_web_proxy_is_busy(void);
void now_web_proxy_status(char *out, long cap);
/* The address Open Transport GRANTED, "host:port", empty when stopped. */
void now_web_proxy_endpoint(char *out, long cap);
/* What the modern Mac last said about a page, from web.response.end. */
void now_web_proxy_note_host(Boolean ok, const char *code, const char *reason);

void now_web_proxy_response_begin(long id, long status,
                                  const char *content_type, long bytes);
void now_web_proxy_response_chunk(long id, long seq, const char *base64);
void now_web_proxy_response_end(long id, Boolean ok, const char *reason);

#endif
