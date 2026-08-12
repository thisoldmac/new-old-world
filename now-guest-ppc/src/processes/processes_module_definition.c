#include "processes_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *processes_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopProcesses,
        "processes",
        "Processes",
        "Everything running on this Mac. Quit asks politely and never forces.",
        "Processes has not moved in yet.",
        "Running applications",
        133,
        kWorkshopModuleTierCore,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        processes_module_ops
    };

    return &definition;
}
