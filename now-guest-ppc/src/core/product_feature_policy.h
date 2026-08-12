#ifndef NOW_PRODUCT_FEATURE_POLICY_H
#define NOW_PRODUCT_FEATURE_POLICY_H

#include "product_features.generated.h"

typedef enum {
    kNowFeatureAdmissionAllowed = 0,
    kNowFeatureAdmissionUnknownFeature = 1,
    kNowFeatureAdmissionExcludedProfile = 2,
    kNowFeatureAdmissionRuntimeFlagDisabled = 3
} NowProductFeatureAdmissionReason;

typedef struct {
    int enabled;
    NowProductFeatureAdmissionReason reason;
    const char *detail;
} NowProductFeatureDecision;

/* Return nonzero when an override was found and write zero or one to value. */
typedef int (*NowProductFeatureFlagLookup)(const char *key,
                                          int *value,
                                          void *context);

NowProductFeatureDecision now_product_feature_decide(
    const NowProductFeatureDefinition *definition,
    NowProductFeatureFlagLookup lookup,
    void *context);
NowProductFeatureDecision now_product_feature_decide_id(
    NowProductFeatureID id,
    NowProductFeatureFlagLookup lookup,
    void *context);

#endif /* NOW_PRODUCT_FEATURE_POLICY_H */
