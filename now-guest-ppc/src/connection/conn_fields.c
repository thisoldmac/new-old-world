#include "conn_fields.h"

int now_conn_ipv4_valid(const char *text)
{
    int octets = 0;
    const char *p = text;

    if (text == 0 || text[0] == '\0') {
        return 0;
    }
    while (*p != '\0') {
        long value = 0;
        int digits = 0;

        while (*p >= '0' && *p <= '9') {
            value = value * 10 + (*p - '0');
            ++digits;
            ++p;
            if (digits > 3) {
                return 0;
            }
        }
        if (digits == 0 || value > 255) {
            return 0;
        }
        ++octets;
        if (*p == '.') {
            ++p;
            if (*p == '\0') {
                return 0;             /* trailing dot */
            }
        } else if (*p != '\0') {
            return 0;                 /* stray character */
        }
    }
    return octets == 4;
}

long now_conn_port_parse(const char *text)
{
    long value = 0;
    const char *p = text;

    if (text == 0 || text[0] == '\0') {
        return -1;
    }
    while (*p >= '0' && *p <= '9') {
        value = value * 10 + (*p - '0');
        if (value > 65535) {
            return -1;
        }
        ++p;
    }
    if (*p != '\0' || value < 1) {
        return -1;
    }
    return value;
}

short now_conn_retry_secs_for_item(short item)
{
    switch (item) {
    case 2:
        return 2;
    case 3:
        return 5;
    case 4:
        return 10;
    default:
        return 0;                     /* automatic backoff */
    }
}

/* Saved values that are not exactly one of the menu's numbers (older
   preferences allowed 0-300) land on the nearest slower choice, so an
   explicit cadence never silently becomes automatic. */
short now_conn_retry_item_for_secs(short secs)
{
    if (secs <= 0) {
        return 1;
    }
    if (secs <= 2) {
        return 2;
    }
    if (secs <= 5) {
        return 3;
    }
    return 4;
}
