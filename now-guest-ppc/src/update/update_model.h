#ifndef NOW_UPDATE_MODEL_H
#define NOW_UPDATE_MODEL_H

typedef enum {
    kNowUpdateApplication = 0,
    kNowUpdateExtension = 1,
    kNowUpdateComponentCount = 2
} NowUpdateComponent;

typedef struct {
    int present;
    char version[24];
    char build[65];
    char sha256[65];
    char channel[16];
    long bytes;
    int signed_artifact;
    int requires_restart;
} NowUpdateOffer;

typedef enum {
    kNowUpdateOfferNone = 0,
    kNowUpdateOfferMatches,
    kNowUpdateOfferScratch,
    kNowUpdateOfferNewer,
    kNowUpdateOfferOlder
} NowUpdateOfferStatus;

void now_update_model_reset(void);
int now_update_component_parse(const char *word, NowUpdateComponent *out);
const char *now_update_component_name(NowUpdateComponent component);
int now_update_offer_set(NowUpdateComponent component,
                         const NowUpdateOffer *offer);
int now_update_offer_get(NowUpdateComponent component, NowUpdateOffer *out);
NowUpdateOfferStatus now_update_offer_status(
    NowUpdateComponent component, const char *installed_version,
    const char *installed_build);
int now_update_offer_differs(NowUpdateComponent component,
                             const char *installed_version,
                             const char *installed_build);
void now_update_offer_line(NowUpdateComponent component,
                           const char *installed_version,
                           const char *installed_build,
                           char *out, long cap);

/* True until the resident table reports the prefix of the exact Extension
   build that was placed on disk. An empty receipt means no activation is
   pending; an absent resident does not round up to success. */
int now_update_extension_pending_activation(const char *pending_build,
                                            const char *active_build);

#endif
