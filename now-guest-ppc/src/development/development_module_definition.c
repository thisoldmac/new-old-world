#include "development_module.h"

#include <stddef.h>

/* The page_id token below and its number (13) are the persisted rail
   order and stay put - see workshop_module.h. stable_id and title are the
   manifest-authority fields this rename (034 G-2) actually touches; the
   WorkshopModuleOps factory name stays development_module_ops, a source
   symbol rather than persisted state, for the same reason the host keeps
   DevelopmentHostModule. */
const WorkshopModuleDefinition *development_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopDevelopment,
        "projects",
        "Projects",
        "Project roots, registered toolchains and headless build jobs on this Mac.",
        "Projects is not in this window yet.",
        "Projects and toolchains",
        144,
        kWorkshopModuleTierExperimental,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        development_module_ops
    };

    return &definition;
}
