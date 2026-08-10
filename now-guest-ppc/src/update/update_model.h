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
    char build[48];
    char sha256[65];
    char channel[16];
    long bytes;
    int signed_artifact;
    int requires_restart;
} NowUpdateOffer;

void now_update_model_reset(void);
int now_update_component_parse(const char *word, NowUpdateComponent *out);
const char *now_update_component_name(NowUpdateComponent component);
int now_update_offer_set(NowUpdateComponent component,
                         const NowUpdateOffer *offer);
int now_update_offer_get(NowUpdateComponent component, NowUpdateOffer *out);
int now_update_offer_differs(NowUpdateComponent component,
                             const char *installed_version,
                             const char *installed_build);
void now_update_offer_line(NowUpdateComponent component,
                           const char *installed_version,
                           const char *installed_build,
                           char *out, long cap);

#endif
