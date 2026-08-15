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
    long i = 0;

    if (out == NULL || cap <= 0) {
        return;
    }
    if (raw_peer_name != NULL) {
        /* A name of nothing but spaces is not a name; wherever this
           string lands, it has to read as one. */
        while (raw_peer_name[i] == ' ' || raw_peer_name[i] == '\t') {
            ++i;
        }
    }
    if (raw_peer_name != NULL && raw_peer_name[i] != '\0') {
        snprintf(out, (size_t)cap, "%s", raw_peer_name + i);
    } else {
        snprintf(out, (size_t)cap, "Other Mac");
    }
}
