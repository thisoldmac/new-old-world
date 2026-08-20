#include "diagnostics_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *diagnostics_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopDiagnostics,
        "diagnostics",
        "Diagnostics",
        "Measurements this Mac can take of itself. Each states "
            "its cost before it runs.",
        "Diagnostics is not in this window yet.",
        "Measure this Mac",
        138,
        kWorkshopModuleTierDebug,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        diagnostics_module_ops
    };

    return &definition;
}
