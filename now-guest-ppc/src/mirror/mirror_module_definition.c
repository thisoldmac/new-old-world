#include "mirror_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *mirror_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopMirror,
        "mirror",
        "Mirror",
        "Mirror's own extensions and agent on this Mac. NOW reads them; it "
            "installs nothing.",
        "Mirror has not moved in yet.",
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
