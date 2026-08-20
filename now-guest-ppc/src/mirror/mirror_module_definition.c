#include "mirror_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *mirror_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopMirror,
        "mirror",
        "Mirror",
        "Mirror's extensions and agent on this Mac. NOW reads them "
            "and installs nothing.",
        "Mirror is not in this window yet.",
        "Its extensions and agent",
        143,
        kWorkshopModuleTierExperimental,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        mirror_module_ops
    };

    return &definition;
}
