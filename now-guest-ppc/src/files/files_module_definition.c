#include "files_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *files_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopFiles,
        "files",
        "Files",
        "Browse Other Mac's share and choose what this Mac shares.",
        "Files is in the File Sharing and peer browser windows.",
        "Browse and exchange",
        130,
        kWorkshopModuleTierCore,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        files_module_ops
    };

    return &definition;
}
