#include "cloud_filter.h"

#include <string.h>

static char fold(char c)
{
    return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
}

void cloud_filter_lower(const char *in, char *out, long cap)
{
    long i;

    if (cap <= 0) {
        return;
    }
    for (i = 0; in[i] != '\0' && i < cap - 1; ++i) {
        out[i] = fold(in[i]);
    }
    out[i] = '\0';
}

Boolean cloud_filter_matches(const char *haystack, const char *needle)
{
    long hn, qn, i;

    if (needle == NULL || needle[0] == '\0') {
        return 1;
    }
    if (haystack == NULL || haystack[0] == '\0') {
        return 0;
    }
    hn = (long)strlen(haystack);
    qn = (long)strlen(needle);
    if (qn > hn) {
        return 0;
    }
    for (i = 0; i <= hn - qn; ++i) {
        long j;

        for (j = 0; j < qn; ++j) {
            if (fold(haystack[i + j]) != needle[j]) {
                break;
            }
        }
        if (j == qn) {
            return 1;
        }
    }
    return 0;
}

Boolean cloud_filter_matches_either(const char *a, const char *b,
                                    const char *needle)
{
    if (needle == NULL || needle[0] == '\0') {
        return 1;
    }
    return cloud_filter_matches(a, needle) || cloud_filter_matches(b, needle);
}
