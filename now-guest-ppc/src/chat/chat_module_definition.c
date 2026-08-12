#include "chat_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *chat_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopChat,
        "chat",
        "Chat",
        "A model on the other Mac's harness, talking about THIS Mac. It "
            "can look at what runs here, with the access MCP grants.",
        "Chat has not moved in yet.",
        "Ask the other Mac's model",
        141,
        kWorkshopModuleTierExperimental,
        NULL,
        0,
        false,
        kNowProductFeatureClassicPowerPC,
        chat_module_ops
    };

    return &definition;
}
