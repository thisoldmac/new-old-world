#include "update_model.h"

#include <stdio.h>
#include <string.h>

static NowUpdateOffer g_offers[kNowUpdateComponentCount];

void now_update_model_reset(void)
{
    memset(g_offers, 0, sizeof g_offers);
}

int now_update_component_parse(const char *word, NowUpdateComponent *out)
{
    if (word != NULL && strcmp(word, "application") == 0) {
        if (out != NULL) *out = kNowUpdateApplication;
        return 1;
    }
    if (word != NULL && strcmp(word, "extension") == 0) {
        if (out != NULL) *out = kNowUpdateExtension;
        return 1;
    }
    return 0;
}

const char *now_update_component_name(NowUpdateComponent component)
{
    return component == kNowUpdateExtension ? "extension" : "application";
}

static int hex_digest(const char *text)
{
    int i;
    if (text == NULL || strlen(text) != 64) return 0;
    for (i = 0; i < 64; ++i) {
        char c = text[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return 0;
    }
    return 1;
}

int now_update_offer_set(NowUpdateComponent component,
                         const NowUpdateOffer *offer)
{
    if (component < 0 || component >= kNowUpdateComponentCount
        || offer == NULL || !offer->present || offer->version[0] == '\0'
        || offer->build[0] == '\0' || offer->bytes <= 0
        || !hex_digest(offer->sha256)) {
        return 0;
    }
    g_offers[component] = *offer;
    g_offers[component].version[sizeof g_offers[component].version - 1] = '\0';
    g_offers[component].build[sizeof g_offers[component].build - 1] = '\0';
    g_offers[component].sha256[64] = '\0';
    g_offers[component].channel[sizeof g_offers[component].channel - 1] = '\0';
    return 1;
}

int now_update_offer_get(NowUpdateComponent component, NowUpdateOffer *out)
{
    if (component < 0 || component >= kNowUpdateComponentCount
        || !g_offers[component].present) return 0;
    if (out != NULL) *out = g_offers[component];
    return 1;
}

int now_update_offer_differs(NowUpdateComponent component,
                             const char *installed_version,
                             const char *installed_build)
{
    const NowUpdateOffer *offer;
    if (component < 0 || component >= kNowUpdateComponentCount
        || !g_offers[component].present) return 0;
    offer = &g_offers[component];
    if (installed_version == NULL || installed_version[0] == '\0') return 1;
    if (strcmp(offer->version, installed_version) != 0) return 1;
    return installed_build == NULL || installed_build[0] == '\0'
        || strcmp(offer->build, installed_build) != 0;
}

void now_update_offer_line(NowUpdateComponent component,
                           const char *installed_version,
                           const char *installed_build,
                           char *out, long cap)
{
    const NowUpdateOffer *offer;
    const char *kind = component == kNowUpdateExtension
        ? "Extension" : "Application";
    if (out == NULL || cap <= 0) return;
    if (!now_update_offer_get(component, NULL)) {
        snprintf(out, (size_t)cap, "%s: host has no update", kind);
        return;
    }
    offer = &g_offers[component];
    if (!now_update_offer_differs(component, installed_version,
                                  installed_build)) {
        snprintf(out, (size_t)cap, "%s: matches host (%s)", kind,
                 offer->version);
        return;
    }
    snprintf(out, (size_t)cap, "%s: %s %s build %.12s%s", kind,
             offer->channel[0] != '\0' ? offer->channel : "available",
             offer->version, offer->build,
             offer->signed_artifact ? " - signed" : " - unsigned");
}
