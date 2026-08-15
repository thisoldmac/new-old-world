#include "connection_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *connection_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopConnection,
        "settings",
        "Connection",
        "This Mac dials Other Mac and keeps one persistent connection.",
        "Connection is still a dialog (Windows menu).",
        NULL,
        132,
        kWorkshopModuleTierCore,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        connection_module_ops
    };

    return &definition;
}
