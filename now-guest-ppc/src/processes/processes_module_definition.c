#include "processes_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *processes_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopProcesses,
        "processes",
        "Processes",
        "Everything running on this Mac. Quit requests; it never forces.",
        "Processes is not in this window yet.",
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
