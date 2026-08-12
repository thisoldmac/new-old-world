#include "development_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *development_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopDevelopment,
        "development",
        "Development",
        "Project roots, registered toolchains and headless build jobs on this Mac.",
        "Development has not moved in yet.",
        "Projects and toolchains",
        144,
        kWorkshopModuleTierExperimental,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        development_module_ops
    };

    return &definition;
}
