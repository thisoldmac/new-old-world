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

static const WorkshopModuleDefinition k_processes_definition = {
    kWorkshopProcesses, "processes", "Processes",
    "Everything running on this Mac. Quit asks politely and never forces.",
    "Processes has not moved in yet.",
    "Running applications", 133, kWorkshopModuleTierCore,
    NULL, 0, false, kNowProductFeatureClassicPowerPC,
    processes_module_ops
};

static const WorkshopModuleDefinition k_mcp_definition = {
    kWorkshopMCP, "mcp", "MCP",
    "Whether an agent may drive this Mac, and how far. The other Mac "
    "runs the server and enforces the answer.",
    "MCP has not moved in yet.",
    "Who may drive this Mac", 137, kWorkshopModuleTierExperimental,
    NULL, 0, false, kNowProductFeatureClassicPowerPC,
    mcp_module_ops
};

static const WorkshopModuleDefinition k_diagnostics_definition = {
    kWorkshopDiagnostics, "diagnostics", "Diagnostics",
    "What this Mac can measure about itself. Each one says what it "
    "costs before it is spent.",
    "Diagnostics has not moved in yet.",
    "Measure this Mac", 138, kWorkshopModuleTierDebug,
    NULL, 0, false, kNowProductFeatureClassicPowerPC,
    diagnostics_module_ops
};

static const WorkshopModuleDefinition k_cloud_definition = {
    kWorkshopCloud, "icloud", "iCloud",
    "The other Mac's iCloud: its Drive, Photos and Contacts, served "
    "one page at a time.",
    "iCloud has not moved in yet.",
    "The other Mac's cloud", 140, kWorkshopModuleTierExperimental,
    NULL, 0, false, kNowProductFeatureClassicPowerPC,
    cloud_module_ops
};

static const WorkshopModuleDefinition k_chat_definition = {
    kWorkshopChat, "chat", "Chat",
    "A model on the other Mac's harness, talking about THIS Mac. It "
    "can look at what runs here, with the access MCP grants.",
    "Chat has not moved in yet.",
    "Ask the other Mac's model", 141, kWorkshopModuleTierExperimental,
    NULL, 0, false, kNowProductFeatureClassicPowerPC,
    chat_module_ops
};

static const WorkshopModuleDefinition k_mirror_definition = {
    kWorkshopMirror, "mirror", "Mirror",
    "Mirror's own extensions and agent on this Mac. NOW reads them; it "
    "installs nothing.",
    "Mirror has not moved in yet.",
    "Its extensions and agent", 143, kWorkshopModuleTierExperimental,
    NULL, 0, false, kNowProductFeatureClassicPowerPC,
    mirror_module_ops
};

static const WorkshopModuleDefinition k_development_definition = {
    kWorkshopDevelopment, "development", "Development",
    "Project roots, registered toolchains and headless build jobs on this Mac.",
    "Development has not moved in yet.",
    "Projects and toolchains", 144, kWorkshopModuleTierExperimental,
    NULL, 0, false, kNowProductFeatureClassicPowerPC,
    development_module_ops
};

static const WorkshopModuleDefinition k_web_definition = {
    kWorkshopWeb, "web", "Web",
    "Modern pages translated on the other Mac for a classic browser here.",
    "Web has not moved in yet.",
    "Classic browser gateway", 145, kWorkshopModuleTierExperimental,
    NULL, 0, false, kNowProductFeatureClassicPowerPC,
    web_module_ops
};

static const WorkshopModuleDefinition k_preferences_definition = {
    kWorkshopPreferences, "settings", "Preferences",
    "How this window behaves. Rearrange the rail by Option-dragging a "
    "row; everything here is remembered between launches.",
    "Preferences has not moved in yet.",
    "How this window behaves", 142, kWorkshopModuleTierCore,
    NULL, 0, false, kNowProductFeatureClassicPowerPC,
    preferences_module_ops
};

static const WorkshopModuleDefinition k_logs_definition = {
    kWorkshopLogs, "logs", "Logs",
    "This launch's event log. Toggle whether it also reaches the disk.",
    "Logs has not moved in yet.",
    "This launch's events", 135, kWorkshopModuleTierDebug,
    NULL, 0, false, kNowProductFeatureClassicPowerPC,
    logs_module_ops
};

static const WorkshopModuleDefinition k_connection_definition = {
    kWorkshopConnection, "settings", "Connection",
    "This Mac dials the other Mac and keeps one persistent connection.",
    "Connection is still a dialog (Windows menu).",
    NULL, 132, kWorkshopModuleTierCore,
    NULL, 0, false, kNowProductFeatureClassicPowerPC,
    connection_module_ops
};

const WorkshopModuleDefinition *workshop_module_definition(
    WorkshopModuleID page_id)
{
    switch (page_id) {
    case kWorkshopScreenshots: return screenshots_module_definition();
    case kWorkshopFiles: return files_module_definition();
    case kWorkshopConsole: return console_module_definition();
    case kWorkshopProcesses: return &k_processes_definition;
    case kWorkshopHardware: return census_module_definition();
    case kWorkshopSoftware: return software_module_definition();
    case kWorkshopMCP: return &k_mcp_definition;
    case kWorkshopDiagnostics: return &k_diagnostics_definition;
    case kWorkshopNetworking: return network_module_definition();
    case kWorkshopCloud: return &k_cloud_definition;
    case kWorkshopChat: return &k_chat_definition;
    case kWorkshopMirror: return &k_mirror_definition;
    case kWorkshopDevelopment: return &k_development_definition;
    case kWorkshopWeb: return &k_web_definition;
    case kWorkshopPreferences: return &k_preferences_definition;
    case kWorkshopLogs: return &k_logs_definition;
    case kWorkshopConnection: return &k_connection_definition;
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
