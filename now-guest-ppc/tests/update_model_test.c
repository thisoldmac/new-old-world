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
    char other_build[65];
    char line[160];

    now_update_model_reset();
    memset(&offer, 0, sizeof offer);
    offer.present = 1;
    strcpy(offer.version, "0.1.0");
    memset(offer.build, 'b', 64);
    offer.build[64] = '\0';
    memset(other_build, 'c', 64);
    other_build[64] = '\0';
    memset(offer.sha256, 'a', 64);
    offer.sha256[64] = '\0';
    strcpy(offer.channel, "development");
    offer.bytes = 42;
    if (!now_update_offer_set(kNowUpdateApplication, &offer))
        return fail("valid offer refused");
    if (!now_update_offer_differs(kNowUpdateApplication,
                                  "0.1.0", other_build))
        return fail("same version, different scratch build hidden");
    if (now_update_offer_differs(kNowUpdateApplication,
                                 "0.1.0", offer.build))
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
                          "0.1.0", other_build, line, sizeof line);
    if (strstr(line, "unsigned") == NULL
        || strstr(line, "development") == NULL)
        return fail("development trust was laundered out of the line");
    offer.sha256[3] = 'Z';
    if (now_update_offer_set(kNowUpdateExtension, &offer))
        return fail("non-hex digest accepted");
    offer.sha256[3] = 'a';
    offer.build[3] = 'Z';
    if (now_update_offer_set(kNowUpdateApplication, &offer))
        return fail("non-hex build identity accepted");
    offer.build[3] = 'b';
    strcpy(offer.version, "0.2");
    if (now_update_offer_set(kNowUpdateApplication, &offer))
        return fail("two-part application version accepted");
    strcpy(offer.version, "1.2.0");
    if (now_update_offer_set(kNowUpdateExtension, &offer))
        return fail("three-part extension version accepted");
    strcpy(offer.version, "1.2");
    if (!now_update_offer_set(kNowUpdateExtension, &offer))
        return fail("valid extension offer refused");
    offer.build[40] = '\0';
    if (now_update_offer_status(kNowUpdateExtension, "1.2", offer.build)
        != kNowUpdateOfferMatches)
        return fail("resident ABI prefix did not match full extension build");
    if (!now_update_extension_pending_activation(other_build, offer.build))
        return fail("different resident cleared a pending activation");
    memcpy(other_build, offer.build, 40);
    if (now_update_extension_pending_activation(other_build, offer.build))
        return fail("matching resident prefix still required a restart");
    if (now_update_extension_pending_activation("", offer.build))
        return fail("empty activation receipt required a restart");
    if (!now_update_extension_pending_activation(other_build, ""))
        return fail("missing resident rounded pending activation up to success");
    return 0;
}
