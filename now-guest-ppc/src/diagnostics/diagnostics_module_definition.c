#include "diagnostics_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *diagnostics_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopDiagnostics,
        "diagnostics",
        "Diagnostics",
        "What this Mac can measure about itself. Each one says what it "
            "costs before it is spent.",
        "Diagnostics has not moved in yet.",
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
