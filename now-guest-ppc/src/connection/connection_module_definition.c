#include "connection_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *connection_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopConnection,
        "settings",
        "Connection",
        "This Mac connects to Other Mac and holds one persistent connection.",
        "Connection is a dialog in the Windows menu.",
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
