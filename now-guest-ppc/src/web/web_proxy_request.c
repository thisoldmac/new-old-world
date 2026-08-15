#include "web_proxy_request.h"

#include <string.h>

static const char *find_bytes(const char *bytes, size_t length,
                              const char *needle, size_t needle_length)
{
    size_t index;
    if (length < needle_length) return NULL;
    for (index = 0; index <= length - needle_length; ++index) {
        if (memcmp(bytes + index, needle, needle_length) == 0)
            return bytes + index;
    }
    return NULL;
}

int now_web_proxy_parse_request(const char *bytes, size_t length,
                                char *method, size_t method_cap,
                                char *target, size_t target_cap)
{
    const char *end, *line_end, *first, *second;
    size_t method_length, target_length, version_length;

    if (bytes == NULL || method == NULL || target == NULL) return -1;
    end = find_bytes(bytes, length, "\r\n\r\n", 4);
    if (end == NULL) end = find_bytes(bytes, length, "\n\n", 2);
    if (end == NULL) return kNowWebRequestIncomplete;
    line_end = find_bytes(bytes, length, "\n", 1);
    if (line_end == NULL) return kNowWebRequestInvalid;
    first = find_bytes(bytes, (size_t)(line_end - bytes), " ", 1);
    if (first == NULL) return kNowWebRequestInvalid;
    second = find_bytes(first + 1, (size_t)(line_end - first - 1), " ", 1);
    if (second == NULL) return kNowWebRequestInvalid;
    method_length = (size_t)(first - bytes);
    target_length = (size_t)(second - first - 1);
    version_length = (size_t)(line_end - second - 1);
    if (version_length > 0 && second[version_length] == '\r')
        --version_length;
    if ((method_length != 3 && method_length != 4)
        || (memcmp(bytes, "GET", 3) != 0
            && memcmp(bytes, "HEAD", 4) != 0)
        || target_length == 0 || target_length + 1 > target_cap
        || method_length + 1 > method_cap || version_length != 8
        || (memcmp(second + 1, "HTTP/1.0", 8) != 0
            && memcmp(second + 1, "HTTP/1.1", 8) != 0)) {
        return kNowWebRequestInvalid;
    }
    memcpy(method, bytes, method_length); method[method_length] = '\0';
    memcpy(target, first + 1, target_length); target[target_length] = '\0';
    return kNowWebRequestReady;
}
