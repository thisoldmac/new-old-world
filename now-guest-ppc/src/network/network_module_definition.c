#include "network_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *network_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopNetworking,
        "networking",
        "Networking",
        "This Mac's link, its address, and the network hardware it has.",
        "Networking has not moved in yet.",
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
