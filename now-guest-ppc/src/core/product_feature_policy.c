#include "product_feature_policy.h"

static NowProductFeatureDecision decision(int enabled,
                                          NowProductFeatureAdmissionReason reason,
                                          const char *detail)
{
    NowProductFeatureDecision result;
    result.enabled = enabled;
    result.reason = reason;
    result.detail = detail;
    return result;
}

NowProductFeatureDecision now_product_feature_decide(
    const NowProductFeatureDefinition *definition,
    NowProductFeatureFlagLookup lookup,
    void *context)
{
    int enabled;

    if (definition == 0) {
        return decision(0, kNowFeatureAdmissionUnknownFeature,
                        "unknown product feature");
    }
    if (definition->release_state == kNowFeatureReleaseExcluded) {
        return decision(0, kNowFeatureAdmissionExcludedProfile,
                        definition->release_note);
    }
    if (definition->runtime_binding != kNowFeatureRuntimeFlag) {
        return decision(1, kNowFeatureAdmissionAllowed, 0);
    }

    enabled = definition->runtime_default;
    if (lookup != 0) {
        int override_value;
        if (lookup(definition->flag_key, &override_value, context)) {
            enabled = override_value != 0;
        }
    }
    if (!enabled) {
        return decision(0, kNowFeatureAdmissionRuntimeFlagDisabled,
                        definition->flag_key);
    }
    return decision(1, kNowFeatureAdmissionAllowed, 0);
}

NowProductFeatureDecision now_product_feature_decide_id(
    NowProductFeatureID id,
    NowProductFeatureFlagLookup lookup,
    void *context)
{
    return now_product_feature_decide(now_product_feature_find(id),
                                      lookup, context);
}
