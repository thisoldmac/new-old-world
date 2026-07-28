#include "ping.h"
#include "json_scan.h"
#include "numfmt.h"

#include <stddef.h>
#include <string.h>

long now68k_ping_build(char *buf, long cap, long id)
{
    long pos = 0;

    if (buf == NULL || cap <= 0) {
        return 0;
    }
    /* Hand-rolled instead of snprintf -- see numfmt.h for why. */
    if (!now68k_fmt_append_str(buf, cap, &pos, "{\"type\":\"ping\",\"id\":")
        || !now68k_fmt_append_long(buf, cap, &pos, id)
        || !now68k_fmt_append_str(buf, cap, &pos, "}")
        || pos >= cap) {
        return 0;
    }
    buf[pos] = '\0';
    return pos;
}

int now68k_pong_read(const char *json, size_t json_len, long *id_out)
{
    char type[16];
    long id;

    if (!now68k_json_read_type(json, json_len, type, (long)sizeof type)) {
        return 0;
    }
    if (strcmp(type, "pong") != 0) {
        return 0;
    }
    if (!now68k_json_find_int(json, json_len, "id", &id)) {
        return 0;   /* Pong.id is required; a pong without one is malformed */
    }
    if (id_out != NULL) {
        *id_out = id;
    }
    return 1;
}
