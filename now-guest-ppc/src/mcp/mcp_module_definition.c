#include "mcp_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *mcp_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopMCP,
        "mcp",
        "MCP",
        "Whether an agent may drive this Mac, and how far. Other Mac "
            "runs the server and enforces it.",
        "MCP is not in this window yet.",
        "Agent access",
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
