#include "logs_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *logs_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopLogs,
        "logs",
        "Logs",
        "This launch's event log. Optionally written to disk.",
        "Logs is not in this window yet.",
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
