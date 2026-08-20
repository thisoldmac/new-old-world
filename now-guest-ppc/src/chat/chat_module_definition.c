#include "chat_module.h"

#include <stddef.h>

const WorkshopModuleDefinition *chat_module_definition(void)
{
    static const WorkshopModuleDefinition definition = {
        kWorkshopChat,
        "chat",
        "Chat",
        "A model running on Other Mac, answering about this Mac. "
            "Its access is what MCP grants.",
        "Chat is not in this window yet.",
        "Ask Other Mac's model",
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
