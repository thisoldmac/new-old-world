#include "screenshots_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *screenshots_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopScreenshots,
        "screen",
        "Screenshots",
        "Capture this Mac, send a still, or stream its screen.",
        "Screenshots is a window in the Windows menu.",
        "Capture and stream",
        129,
        kWorkshopModuleTierCore,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        screenshots_module_ops
    };

    return &definition;
}
