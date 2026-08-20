#include "cloud_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *cloud_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopCloud,
        "icloud",
        "iCloud",
        "Other Mac's iCloud Drive, Photos and Contacts, one page "
            "at a time.",
        "iCloud is not in this window yet.",
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
