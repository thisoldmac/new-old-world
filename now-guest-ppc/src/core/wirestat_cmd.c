#include "wirestat_cmd.h"

#include <stdlib.h>
#include <string.h>

static const char *skip_spaces(const char *p)
{
    while (*p == ' ' || *p == '\t') {
        ++p;
    }
    return p;
}

static const char *take_word(const char *p, char *out, long cap)
{
    long i = 0;

    p = skip_spaces(p);
    while (*p != '\0' && *p != ' ' && *p != '\t' && i < cap - 1) {
        out[i++] = *p++;
    }
    out[i] = '\0';
    /* Past the rest of an over-long word, so the NEXT word is still the
       next word rather than this one's tail. */
    while (*p != '\0' && *p != ' ' && *p != '\t') {
        ++p;
    }
    return p;
}

void now_wirestat_split(const char *line, char *action, long acap,
                        char *value, long vcap)
{
    if (action != NULL && acap > 0) {
        action[0] = '\0';
    }
    if (value != NULL && vcap > 0) {
        value[0] = '\0';
    }
    if (line == NULL) {
        return;
    }
    line = take_word(line, action, acap);
    (void)take_word(line, value, vcap);
}

void now_wirestat_parse(const char *action, const char *value,
                        WireStatRequest *out)
{
    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof *out);
    if (action == NULL) {
        return;
    }
    if (strcmp(action, "reset") == 0) {
        out->reset = 1;
    } else if (strcmp(action, "wake") == 0) {
        out->set_wake = 1;
        /* Anything but the word "off" turns it on, so `wirestat wake`
           bare does the harmless thing rather than the surprising one. */
        out->wake_on = (value == NULL || strcmp(value, "off") != 0);
    } else if (strcmp(action, "sleep") == 0) {
        out->set_sleep = 1;
        out->sleep_ticks = value != NULL ? atol(value) : 0;
    }
}
