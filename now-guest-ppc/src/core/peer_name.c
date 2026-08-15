#include "peer_name.h"

#include <stdio.h>

void now_self_name(char *out, long cap)
{
    if (out == NULL || cap <= 0) {
        return;
    }
    snprintf(out, (size_t)cap, "This Mac");
}

void now_peer_name(const char *raw_peer_name, char *out, long cap)
{
    if (out == NULL || cap <= 0) {
        return;
    }
    if (raw_peer_name != NULL && raw_peer_name[0] != '\0') {
        snprintf(out, (size_t)cap, "%s", raw_peer_name);
    } else {
        snprintf(out, (size_t)cap, "Other Mac");
    }
}
