#include "web_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *web_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopWeb,
        "web",
        "Web",
        "Modern pages translated on the other Mac for a classic browser here.",
        "Web has not moved in yet.",
        "Classic browser gateway",
        145,
        kWorkshopModuleTierExperimental,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        web_module_ops
    };

    return &definition;
}
