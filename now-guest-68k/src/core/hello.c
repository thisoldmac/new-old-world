#include "hello.h"
#include "numfmt.h"

#include <stddef.h>

long now68k_hello_build(char *buf, long cap, long contract,
                         const char *app_version)
{
    long pos = 0;

    if (buf == NULL || cap <= 0 || app_version == NULL) {
        return 0;
    }
    /* Hand-rolled instead of snprintf -- see numfmt.h for why. */
    if (!now68k_fmt_append_str(buf, cap, &pos,
                                "{\"type\":\"hello\",\"contract\":")
        || !now68k_fmt_append_long(buf, cap, &pos, contract)
        || !now68k_fmt_append_str(buf, cap, &pos,
                                   ",\"side\":\"guest\",\"version\":\"")
        || !now68k_fmt_append_str(buf, cap, &pos, app_version)
        || !now68k_fmt_append_str(buf, cap, &pos,
                                   "\",\"name\":\"" NOW68K_HELLO_NAME
                                   "\",\"os\":\"" NOW68K_HELLO_OS
                                   "\",\"chunk\":")
        || !now68k_fmt_append_long(buf, cap, &pos, NOW68K_HELLO_CHUNK)
        || !now68k_fmt_append_str(buf, cap, &pos, "}")
        || pos >= cap) {
        return 0;
    }
    buf[pos] = '\0';
    return pos;
}
