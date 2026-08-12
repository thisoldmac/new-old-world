#include "logs_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *logs_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopLogs,
        "logs",
        "Logs",
        "This launch's event log. Toggle whether it also reaches the disk.",
        "Logs has not moved in yet.",
        "This launch's events",
        135,
        kWorkshopModuleTierDebug,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        logs_module_ops
    };

    return &definition;
}
