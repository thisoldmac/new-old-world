#ifndef NOW_WEB_PROXY_REQUEST_H
#define NOW_WEB_PROXY_REQUEST_H

#include <stddef.h>

enum {
    kNowWebRequestIncomplete = 0,
    kNowWebRequestReady = 1,
    kNowWebRequestInvalid = -1
};

int now_web_proxy_parse_request(const char *bytes, size_t length,
                                char *method, size_t method_cap,
                                char *target, size_t target_cap);

#endif
