/* The command.result envelope. See mach_reply.h. */

#include "mach_reply.h"

#include <stdio.h>

#include "json.h"

void now_mach_rows_reset(NowMachRows *r)
{
    r->rows[0] = '\0';
    r->used = 0;
    r->overflow = 0;
}

void now_mach_row(NowMachRows *r, const char *label, const char *value)
{
    char esc_label[64];
    char esc_value[512];
    int  n;

    if (r->overflow) {
        return;
    }
    now_json_escape(label, esc_label, (long)sizeof esc_label);
    now_json_escape(value, esc_value, (long)sizeof esc_value);
    n = snprintf(r->rows + r->used, (size_t)((long)sizeof r->rows - r->used),
                 "%s[\"%s\",\"%s\"]", r->used > 0 ? "," : "",
                 esc_label, esc_value);
    if (n < 0 || (long)n >= (long)sizeof r->rows - r->used) {
        r->overflow = 1;
        return;
    }
    r->used += n;
}

void now_mach_rowf(NowMachRows *r, const char *label, const char *fmt,
                   unsigned long v)
{
    char value[64];

    snprintf(value, sizeof value, fmt, v);
    now_mach_row(r, label, value);
}

void now_mach_reply_rows(char *out, long cap, long id, const char *name,
                         const NowMachRows *r)
{
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"%s\":[%s]}}", id, name, r->rows);
}

void now_mach_reply_error(char *out, long cap, long id, const char *code,
                          const char *message)
{
    char esc[512];

    now_json_escape(message, esc, (long)sizeof esc);
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
             "\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}",
             id, code, esc);
}
