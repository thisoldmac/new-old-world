#include "workshop_registry.h"

#include <stddef.h>

#include "census_module.h"
#include "chat_module.h"
#include "cloud_module.h"
#include "connection_module.h"
#include "console_module.h"
#include "development_module.h"
#include "diagnostics_module.h"
#include "files_module.h"
#include "logs_module.h"
#include "mcp_module.h"
#include "mirror_module.h"
#include "network_module.h"
#include "preferences_module.h"
#include "processes_module.h"
#include "screenshots_module.h"
#include "software_module.h"
#include "web_module.h"

/* One ordered composition list, indexed by the persisted Workshop page id.
   Definitions own metadata and construction; the registry only establishes
   product order and rejects a definition filed under the wrong stable id. */
static const WorkshopModuleDefinitionFactory k_module_definitions[] = {
    screenshots_module_definition,
    files_module_definition,
    console_module_definition,
    processes_module_definition,
    census_module_definition,
    software_module_definition,
    mcp_module_definition,
    diagnostics_module_definition,
    network_module_definition,
    cloud_module_definition,
    chat_module_definition,
    mirror_module_definition,
    development_module_definition,
    web_module_definition,
    preferences_module_definition,
    logs_module_definition,
    connection_module_definition,
};

const WorkshopModuleDefinition *workshop_module_definition(
    WorkshopModuleID page_id)
{
    const WorkshopModuleDefinition *definition;
    int index = (int)page_id - 1;

    if (index < 0 || index >= kWorkshopModuleCount ||
        (int)(sizeof(k_module_definitions) /
              sizeof(k_module_definitions[0])) != kWorkshopModuleCount) {
        return NULL;
    }
    definition = k_module_definitions[index]();
    return definition != NULL && definition->page_id == page_id
        ? definition : NULL;
}

Boolean workshop_registry_prepare(
    WorkshopModuleInstance *instances,
    short instance_count,
    NowProductFeatureFlagLookup flag_lookup,
    void *flag_context)
{
    short page;

    if (instances == NULL || instance_count < kWorkshopModuleCount + 1) {
        return false;
    }
    instances[0].definition = NULL;
    instances[0].ops = NULL;
    instances[0].admitted = false;
    instances[0].unavailable_reason = NULL;
    instances[0].created = 0;
    for (page = 1; page <= kWorkshopModuleCount; ++page) {
        WorkshopModuleInstance *instance = &instances[page];
        NowProductFeatureDecision admission;

        instance->definition = workshop_module_definition(
            (WorkshopModuleID)page);
        if (instance->definition == NULL) {
            return false;
        }
        instance->ops = instance->definition->ops_factory != NULL
            ? instance->definition->ops_factory() : NULL;
        instance->admitted = true;
        instance->unavailable_reason = NULL;
        instance->created = 0;
        if (!instance->definition->has_feature) {
            continue;
        }
        admission = now_product_feature_decide_id(
            instance->definition->feature_id, flag_lookup, flag_context);
        instance->admitted = admission.enabled != 0;
        instance->unavailable_reason = admission.enabled
            ? NULL : admission.detail;
    }
    return true;
}
