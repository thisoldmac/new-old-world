#include "console_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *console_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopConsole,
        "console",
        "Console",
        "Commands run on this Mac. Only declared commands are available.",
        "Console still lives in its own window (Windows menu).",
        "Local commands",
        131,
        kWorkshopModuleTierCore,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        console_module_ops
    };

    return &definition;
}
