#include "preferences_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *preferences_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopPreferences,
        "settings",
        "Preferences",
        "How this window behaves. Rearrange the rail by dragging a row; "
            "everything here is remembered between launches.",
        "Preferences has not moved in yet.",
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
