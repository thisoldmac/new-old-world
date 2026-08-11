#include "web_model.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void check(int ok, const char *name)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", name);
        failures++;
    }
}

int main(void)
{
    char text[160];

    check(now_web_profile_sanitize(0) == kNowWebProfileClassilla,
          "bad profile falls back to Classilla");
    check(now_web_profile_sanitize(2) == kNowWebProfileMacWeb,
          "MacWeb profile survives");
    check(now_web_lens_sanitize(99) == kNowWebLensCompatible,
          "bad lens falls back to Compatible");
    check(strcmp(now_web_profile_token(kNowWebProfileGeneric68K),
                 "generic68k") == 0, "generic token");
    check(strcmp(now_web_lens_name(kNowWebLensReader), "Reader") == 0,
          "reader title");
    now_web_endpoint("10.0.2.2", 5180, text, sizeof text);
    check(strcmp(text, "10.0.2.2:5180") == 0, "QEMU endpoint");
    now_web_start_url("192.168.1.20", 8181, kNowWebProfileMacWeb,
                      kNowWebLensReader, text, sizeof text);
    check(strcmp(text, "http://192.168.1.20:8181/"
                       "?profile=macweb&lens=reader") == 0,
          "hardware URL carries active settings");
    now_web_endpoint("host", 5180, text, 6);
    check(text[5] == '\0', "bounded formatting");

    if (failures) return 1;
    puts("web model: ok");
    return 0;
}
