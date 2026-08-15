#include "cloud_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *cloud_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopCloud,
        "icloud",
        "iCloud",
        "Other Mac's iCloud: its Drive, Photos and Contacts, served "
            "one page at a time.",
        "iCloud has not moved in yet.",
        "Other Mac's cloud",
        140,
        kWorkshopModuleTierExperimental,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        cloud_module_ops
    };

    return &definition;
}
