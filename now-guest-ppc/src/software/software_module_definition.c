#include "software_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *software_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopSoftware,
        "software",
        "Software",
        "Installed software on this Mac, and starting it. Applications "
        "scan the disk; the rest read the System Folder.",
        "Software is not in this window yet.",
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
