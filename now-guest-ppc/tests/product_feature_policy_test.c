#include "product_feature_policy.h"

#include <assert.h>
#include <string.h>

static int enabled_override(const char *key, int *value, void *context)
{
    (void)context;
    assert(strcmp(key, "classic.pre-carbon") == 0);
    *value = 1;
    return 1;
}

int main(void)
{
    NowProductFeatureDecision result;
    NowProductFeatureDefinition included_flag;

    result = now_product_feature_decide_id(kNowProductFeatureClassicPowerPC,
                                           0, 0);
    assert(result.enabled);
    assert(result.reason == kNowFeatureAdmissionAllowed);

    result = now_product_feature_decide_id(kNowProductFeatureResidentExtension,
                                           0, 0);
    assert(result.enabled); /* Capability negotiation is a separate answer. */

    result = now_product_feature_decide_id(kNowProductFeatureClassicPreCarbon,
                                           enabled_override, 0);
    assert(!result.enabled);
    assert(result.reason == kNowFeatureAdmissionExcludedProfile);
    assert(strstr(result.detail, "stale") != 0);

    included_flag = kNowProductFeatures[kNowProductFeatureClassicPreCarbon];
    included_flag.release_state = kNowFeatureReleaseIncluded;
    result = now_product_feature_decide(&included_flag, 0, 0);
    assert(!result.enabled);
    assert(result.reason == kNowFeatureAdmissionRuntimeFlagDisabled);
    assert(strcmp(result.detail, "classic.pre-carbon") == 0);

    result = now_product_feature_decide(&included_flag, enabled_override, 0);
    assert(result.enabled);
    assert(result.reason == kNowFeatureAdmissionAllowed);

    result = now_product_feature_decide(0, 0, 0);
    assert(!result.enabled);
    assert(result.reason == kNowFeatureAdmissionUnknownFeature);
    return 0;
}
