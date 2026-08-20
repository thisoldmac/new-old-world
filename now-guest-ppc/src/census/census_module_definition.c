#include "census_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *census_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopHardware,
        "census",
        "Hardware",
        "This Mac's hardware, probe by probe. Probes run on request, not at idle.",
        "Hardware census is not built into this window yet.",
        "Census and probes",
        134,
        kWorkshopModuleTierCore,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        census_module_ops
    };

    return &definition;
}
