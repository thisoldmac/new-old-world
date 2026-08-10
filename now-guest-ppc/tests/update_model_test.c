#include <stdio.h>
#include <string.h>

#include "update_model.h"

static int fail(const char *text)
{
    fprintf(stderr, "%s\n", text);
    return 1;
}

int main(void)
{
    NowUpdateOffer offer;
    char line[160];

    now_update_model_reset();
    memset(&offer, 0, sizeof offer);
    offer.present = 1;
    strcpy(offer.version, "0.1.0");
    strcpy(offer.build, "scratch123456");
    memset(offer.sha256, 'a', 64);
    offer.sha256[64] = '\0';
    strcpy(offer.channel, "development");
    offer.bytes = 42;
    if (!now_update_offer_set(kNowUpdateApplication, &offer))
        return fail("valid offer refused");
    if (!now_update_offer_differs(kNowUpdateApplication,
                                  "0.1.0", "release123456"))
        return fail("same version, different scratch build hidden");
    if (now_update_offer_differs(kNowUpdateApplication,
                                 "0.1.0", "scratch123456"))
        return fail("matching exact build called an update");
    if (now_update_offer_status(kNowUpdateApplication,
                                "0.2.0", "newer-installed")
        != kNowUpdateOfferOlder)
        return fail("older host release was offered as an update");
    now_update_offer_line(kNowUpdateApplication,
                          "0.2.0", "newer-installed", line, sizeof line);
    if (strstr(line, "host has older") == NULL)
        return fail("older host release was not explained");
    now_update_offer_line(kNowUpdateApplication,
                          "0.1.0", "release123456", line, sizeof line);
    if (strstr(line, "unsigned") == NULL
        || strstr(line, "development") == NULL)
        return fail("development trust was laundered out of the line");
    offer.sha256[3] = 'Z';
    if (now_update_offer_set(kNowUpdateExtension, &offer))
        return fail("non-hex digest accepted");
    offer.sha256[3] = 'a';
    strcpy(offer.version, "0.2");
    if (now_update_offer_set(kNowUpdateApplication, &offer))
        return fail("two-part application version accepted");
    strcpy(offer.version, "1.2.0");
    if (now_update_offer_set(kNowUpdateExtension, &offer))
        return fail("three-part extension version accepted");
    return 0;
}
