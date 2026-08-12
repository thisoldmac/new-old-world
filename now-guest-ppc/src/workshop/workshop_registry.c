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

const WorkshopModuleDefinition *workshop_module_definition(
    WorkshopModuleID page_id)
{
    switch (page_id) {
    case kWorkshopScreenshots: return screenshots_module_definition();
    case kWorkshopFiles: return files_module_definition();
    case kWorkshopConsole: return console_module_definition();
    case kWorkshopProcesses: return processes_module_definition();
    case kWorkshopHardware: return census_module_definition();
    case kWorkshopSoftware: return software_module_definition();
    case kWorkshopMCP: return mcp_module_definition();
    case kWorkshopDiagnostics: return diagnostics_module_definition();
    case kWorkshopNetworking: return network_module_definition();
    case kWorkshopCloud: return cloud_module_definition();
    case kWorkshopChat: return chat_module_definition();
    case kWorkshopMirror: return mirror_module_definition();
    case kWorkshopDevelopment: return development_module_definition();
    case kWorkshopWeb: return web_module_definition();
    case kWorkshopPreferences: return preferences_module_definition();
    case kWorkshopLogs: return logs_module_definition();
    case kWorkshopConnection: return connection_module_definition();
    default: return NULL;
    }
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
