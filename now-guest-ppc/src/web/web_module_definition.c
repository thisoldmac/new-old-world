#include "web_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *web_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopWeb,
        "web",
        "Web",
        "Modern pages translated on Other Mac for a classic browser here.",
        "Web is not in this window yet.",
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
