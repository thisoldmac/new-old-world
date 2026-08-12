#include "software_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *software_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopSoftware,
        "software",
        "Software",
        "What is installed on this Mac, and starting it. Applications sweep "
        "the disk; the rest read the System Folder.",
        "Software has not moved in yet.",
        "What is installed",
        136,
        kWorkshopModuleTierCore,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        software_module_ops
    };

    return &definition;
}
