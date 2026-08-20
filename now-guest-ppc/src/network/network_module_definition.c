#include "network_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *network_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopNetworking,
        "networking",
        "Networking",
        "This Mac's link, address and network hardware.",
        "Networking is not in this window yet.",
        "Link, address and ports",
        139,
        kWorkshopModuleTierCore,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        network_module_ops
    };

    return &definition;
}
