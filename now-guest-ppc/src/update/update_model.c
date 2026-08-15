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

static int release_version(const char *text, int expected_parts,
                           unsigned long parts[3])
{
    int count = 0;
    const char *p = text;
    if (text == NULL || text[0] == '\0') return 0;
    while (count < expected_parts) {
        unsigned long value = 0;
        int digits = 0;
        while (*p >= '0' && *p <= '9') {
            if (value > 6553UL) return 0;
            value = value * 10UL + (unsigned long)(*p - '0');
            ++p;
            ++digits;
        }
        if (!digits) return 0;
        parts[count++] = value;
        if (count == expected_parts) return *p == '\0';
        if (*p++ != '.') return 0;
    }
    return 0;
}

static int release_compare(const unsigned long left[3],
                           const unsigned long right[3], int count)
{
    int i;
    for (i = 0; i < count; ++i) {
        if (left[i] < right[i]) return -1;
        if (left[i] > right[i]) return 1;
    }
    return 0;
}

int now_update_offer_set(NowUpdateComponent component,
                         const NowUpdateOffer *offer)
{
    unsigned long version[3];
    int version_parts = component == kNowUpdateExtension ? 2 : 3;
    if (component < 0 || component >= kNowUpdateComponentCount
        || offer == NULL || !offer->present || offer->version[0] == '\0'
        || offer->build[0] == '\0' || offer->bytes <= 0
        || !hex_digest(offer->build) || !hex_digest(offer->sha256)
        || !release_version(offer->version, version_parts, version)) {
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

NowUpdateOfferStatus now_update_offer_status(
    NowUpdateComponent component, const char *installed_version,
    const char *installed_build)
{
    const NowUpdateOffer *offer;
    unsigned long offered[3];
    unsigned long installed[3];
    int parts;
    int order;
    if (component < 0 || component >= kNowUpdateComponentCount
        || !g_offers[component].present) return kNowUpdateOfferNone;
    offer = &g_offers[component];
    if (installed_version == NULL || installed_version[0] == '\0')
        return kNowUpdateOfferNewer;
    parts = component == kNowUpdateExtension ? 2 : 3;
    if (!release_version(offer->version, parts, offered)
        || !release_version(installed_version, parts, installed)) {
        return kNowUpdateOfferNone;
    }
    order = release_compare(offered, installed, parts);
    if (order > 0) return kNowUpdateOfferNewer;
    if (order < 0) return kNowUpdateOfferOlder;
    if (installed_build == NULL || installed_build[0] == '\0') {
        return kNowUpdateOfferScratch;
    }
    if (component == kNowUpdateExtension) {
        /* The resident table's shipped ABI carries five 32-bit words. Its
           160-bit prefix is deliberately compared with the full 256-bit
           publication identity; the request and artifact digest still bind
           all 256 bits and the exact MacBinary respectively. */
        if (strlen(installed_build) != 40
            || strncmp(offer->build, installed_build, 40) != 0) {
            return kNowUpdateOfferScratch;
        }
    } else if (strcmp(offer->build, installed_build) != 0) {
        return kNowUpdateOfferScratch;
    }
    return kNowUpdateOfferMatches;
}

int now_update_offer_differs(NowUpdateComponent component,
                             const char *installed_version,
                             const char *installed_build)
{
    NowUpdateOfferStatus status = now_update_offer_status(
        component, installed_version, installed_build);
    return status == kNowUpdateOfferNewer
        || status == kNowUpdateOfferScratch;
}

void now_update_offer_line(NowUpdateComponent component,
                           const char *installed_version,
                           const char *installed_build,
                           char *out, long cap)
{
    const NowUpdateOffer *offer;
    NowUpdateOfferStatus status;
    const char *kind = component == kNowUpdateExtension
        ? "Extension" : "Application";
    if (out == NULL || cap <= 0) return;
    if (!now_update_offer_get(component, NULL)) {
        snprintf(out, (size_t)cap, "%s: host has no update", kind);
        return;
    }
    offer = &g_offers[component];
    status = now_update_offer_status(component, installed_version,
                                     installed_build);
    if (status == kNowUpdateOfferMatches) {
        snprintf(out, (size_t)cap, "%s: matches host (%s)", kind,
                 offer->version);
        return;
    }
    if (status == kNowUpdateOfferOlder) {
        snprintf(out, (size_t)cap, "%s: host has older %s (installed %s)",
                 kind, offer->version, installed_version);
        return;
    }
    if (status == kNowUpdateOfferNone) {
        snprintf(out, (size_t)cap, "%s: invalid host offer", kind);
        return;
    }
    snprintf(out, (size_t)cap, "%s: %s %s build %.12s%s", kind,
             offer->channel[0] != '\0' ? offer->channel : "available",
             offer->version, offer->build,
             offer->signed_artifact ? " - signed" : " - unsigned");
}

int now_update_extension_pending_activation(const char *pending_build,
                                            const char *active_build)
{
    if (pending_build == NULL || pending_build[0] == '\0') return 0;
    if (strlen(pending_build) != 64 || active_build == NULL
        || strlen(active_build) != 40) return 1;
    return strncmp(pending_build, active_build, 40) != 0;
}
