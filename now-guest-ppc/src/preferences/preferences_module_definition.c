#include "preferences_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *preferences_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopPreferences,
        "settings",
        "Preferences",
        "How this window behaves. Drag a row to rearrange the rail; "
            "settings are saved between launches.",
        "Preferences is not in this window yet.",
        "How this window behaves",
        142,
        kWorkshopModuleTierCore,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        preferences_module_ops
    };

    return &definition;
}
