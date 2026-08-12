#include "mcp_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *mcp_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopMCP,
        "mcp",
        "MCP",
        "Whether an agent may drive this Mac, and how far. The other Mac "
            "runs the server and enforces the answer.",
        "MCP has not moved in yet.",
        "Who may drive this Mac",
        137,
        kWorkshopModuleTierExperimental,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        mcp_module_ops
    };

    return &definition;
}
