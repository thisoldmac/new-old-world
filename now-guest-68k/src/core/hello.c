#include "hello.h"
#include "numfmt.h"

#include <stddef.h>

/* One character into the buffer, with the same append contract as
   numfmt.h: 1 if it fit, 0 if it did not, nothing half-written. */
static int put_ch(char *buf, long cap, long *pos, char c)
{
    if (*pos + 1 >= cap) {
        return 0;
    }
    buf[(*pos)++] = c;
    return 1;
}

/* `model` is the only field in this message that is not ours.
 *
 * Every other value here is a compile-time literal or a number. The
 * model comes from Gestalt 'mnam' or a 'STR ' resource - whatever
 * somebody's System says the machine is - so it is the one string that
 * could carry a quote or a backslash and reopen the JSON around it.
 *
 * This guest's JSON writer does not escape (wire68.c says so in three
 * places), and the pattern it uses where peer text must be embedded is
 * to replace the two characters that could break out rather than to
 * carry a full escaper: cheaper, and sufficient because the field is a
 * display name and not a payload. The same choice is made here, in the
 * builder rather than in the caller, so it cannot be forgotten by the
 * next caller.
 *
 * Control characters go the same way. A raw newline inside a JSON string
 * is invalid, and a machine name is not a place to discover that. */
static int append_model(char *buf, long cap, long *pos, const char *model)
{
    if (model == NULL) {
        return 1;
    }
    while (*model != '\0') {
        unsigned char c = (unsigned char)*model++;

        if (c == '"' || c == '\\') {
            c = '\'';
        } else if (c < 0x20) {
            c = ' ';
        }
        if (!put_ch(buf, cap, pos, (char)c)) {
            return 0;
        }
    }
    return 1;
}

long now68k_hello_build(char *buf, long cap, long contract,
                         const char *app_version,
                         const char *system_version,
                         long machine_id, const char *machine_model)
{
    long pos = 0;

    if (buf == NULL || cap <= 0 || app_version == NULL) {
        return 0;
    }
    /* `os` and `machine` are ARGUMENTS now, not literals in hello.h.
       They were NOW68K_HELLO_OS ("7.1") - a compile-time constant that
       claimed to describe the machine and really described the build, so
       it could not notice a System upgrade and could not key anything.
       They are passed in rather than read here because this file is
       deliberately Toolbox-free: that is what lets the host cc compile
       and run it in test_framecodec, and a Gestalt call would cost it.
       A caller with nothing to say passes `unknown` and 0 - both are
       first-class values meaning "we could not establish it", and
       neither is a gap for a receiver to fill in. */
    /* Hand-rolled instead of snprintf -- see numfmt.h for why. */
    if (!now68k_fmt_append_str(buf, cap, &pos,
                                "{\"type\":\"hello\",\"contract\":")
        || !now68k_fmt_append_long(buf, cap, &pos, contract)
        || !now68k_fmt_append_str(buf, cap, &pos,
                                   ",\"side\":\"guest\",\"version\":\"")
        || !now68k_fmt_append_str(buf, cap, &pos, app_version)
        || !now68k_fmt_append_str(buf, cap, &pos,
                                   "\",\"name\":\"" NOW68K_HELLO_NAME
                                   "\",\"os\":\"")
        || !now68k_fmt_append_str(buf, cap, &pos,
                                   system_version != NULL
                                   ? system_version : kNowIdentityUnknown)
        || !now68k_fmt_append_str(buf, cap, &pos, "\",\"machine\":{\"id\":")
        || !now68k_fmt_append_long(buf, cap, &pos, machine_id)
        || !now68k_fmt_append_str(buf, cap, &pos, ",\"model\":\"")
        || !append_model(buf, cap, &pos, machine_model)
        || !now68k_fmt_append_str(buf, cap, &pos, "\"},\"chunk\":")
        || !now68k_fmt_append_long(buf, cap, &pos, NOW68K_HELLO_CHUNK)
        || !now68k_fmt_append_str(buf, cap, &pos, "}")
        || pos >= cap) {
        return 0;
    }
    buf[pos] = '\0';
    return pos;
}
