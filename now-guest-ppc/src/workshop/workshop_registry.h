#ifndef NOW_WORKSHOP_REGISTRY_H
#define NOW_WORKSHOP_REGISTRY_H

#include "product_feature_policy.h"
#include "workshop_module.h"

const WorkshopModuleDefinition *workshop_module_definition(
    WorkshopModuleID page_id);

/* Resolve the statically linked definition, ops table and product admission
   for every page as one operation before the window can select anything. */
Boolean workshop_registry_prepare(
    WorkshopModuleInstance *instances,
    short instance_count,
    NowProductFeatureFlagLookup flag_lookup,
    void *flag_context);

#endif /* NOW_WORKSHOP_REGISTRY_H */
