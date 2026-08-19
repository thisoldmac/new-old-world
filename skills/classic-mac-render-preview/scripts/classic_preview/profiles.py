PROFILES = {
    "system6-compact": {
        "os": "System 6.0.4-6.0.8",
        "cpu": "68K",
        "api_model": "non-Carbon Toolbox",
        "appearance": "classic-monochrome",
        "chrome_model": "classic-monochrome",
        "chrome_routes": ["Window Manager", "Control Manager resources"],
        "screen": {"width": 512, "height": 342, "depth": 1},
        "allowed_depths": [1],
    },
    "system7-classic": {
        "os": "System 7.0-7.6.1",
        "cpu": "68K or PowerPC",
        "api_model": "non-Carbon Toolbox",
        "appearance": "classic",
        "chrome_model": "system7-classic",
        "chrome_routes": ["Window Manager", "Control Manager resources"],
        "screen": {"width": 640, "height": 480, "depth": 4},
        "allowed_depths": [1, 4, 8],
    },
    "platinum-toolbox": {
        "os": "Mac OS 8.0-9.2.2",
        "cpu": "68K or PowerPC",
        "api_model": "non-Carbon Toolbox plus Appearance Manager",
        "appearance": "platinum",
        "chrome_model": "appearance-manager-platinum",
        "chrome_routes": ["Window Manager", "SetThemeWindowBackground", "Appearance Manager control resources"],
        "screen": {"width": 800, "height": 600, "depth": 8},
        "allowed_depths": [1, 4, 8],
    },
    "platinum-carbonlib": {
        "os": "Mac OS 8.6-9.2.2",
        "cpu": "PowerPC CFM",
        "api_model": "CarbonLib 1.6",
        "appearance": "platinum",
        "chrome_model": "appearance-manager-platinum",
        "chrome_routes": ["CreateNewWindow", "CreateRootControl", "SetThemeWindowBackground", "Appearance Manager theme drawing"],
        "calibration": {
            "id": "macos91-carbonlib16-native-exemplar-v4",
            "runtime": "Mac OS 9.1, mac99, 800x600x8",
            "evidence": "references/observed-carbonlib-16-os91.md",
        },
        "screen": {"width": 800, "height": 600, "depth": 8},
        "allowed_depths": [1, 4, 8],
    },
}

BASE_COMPONENT_STATUS = {
    "label": "native-api-route",
    "separator": "native-api-route",
    "button": "native-resource-route",
    "checkbox": "native-resource-route",
    "radio": "native-resource-route",
    "field": "native-resource-route",
    "group": "native-resource-route",
    "list": "native-api-route",
    "scrollbar": "native-resource-route",
    "icon": "custom-required",
    "quickdraw_canvas": "custom-required",
}

FALLBACKS = {
    "databrowser": {"list"},
    "tabs": {"group"},
    "progress": {"thermometer"},
    "bevel_button": {"button"},
    "placard": {"group"},
    "popup": {"list"},
    "slider": {"field"},
    "little_arrows": {"field"},
    "disclosure": {"button"},
    "image_well": {"group"},
    "system_icon": {"icon"},
    "text_area": {"field"},
}

CARBON_PRIMITIVES = {
    "label": "CreateStaticTextControl",
    "separator": "CreateSeparatorControl",
    "button": "CreatePushButtonControl",
    "checkbox": "CreateCheckBoxControl",
    "radio": "CreateRadioButtonControl",
    "field": "CreateEditTextControl",
    "group": "CreateGroupBoxControl",
    "list": "CreateListBoxControl",
    "scrollbar": "CreateScrollBarControl",
    "tabs": "CreateTabsControl + CreateUserPaneControl + EmbedControl",
    "progress": "CreateProgressBarControl",
    "databrowser": "CreateDataBrowserControl",
    "bevel_button": "CreateBevelButtonControl",
    "placard": "CreatePlacardControl",
    "popup": "CreatePopupButtonControl",
    "slider": "CreateSliderControl",
    "little_arrows": "CreateLittleArrowsControl",
    "disclosure": "CreateDisclosureTriangleControl",
    "image_well": "CreateImageWellControl",
    "system_icon": "CreateIconControl + GetIconRef",
    "text_area": "TXNNewObject + TXNSetBackground (MLTE)",
    "quickdraw_canvas": "QuickDraw offscreen GWorld + CopyBits",
    "icon": "QuickDraw original planning glyph",
}

RESOURCE_PRIMITIVES = {
    "label": "DrawString/TextEdit",
    "separator": "Appearance separator CNTL resource",
    "button": "push-button CNTL resource",
    "checkbox": "checkbox CNTL resource",
    "radio": "radio-button CNTL resource",
    "field": "edit-text DITL item",
    "group": "group-box CNTL resource",
    "list": "List Manager",
    "scrollbar": "scrollbar CNTL resource",
    "tabs": "Appearance tab CNTL resource",
    "progress": "Appearance progress CNTL resource",
    "bevel_button": "Appearance bevel-button CNTL resource",
    "placard": "Appearance placard CNTL resource",
    "popup": "Appearance pop-up CNTL resource",
    "slider": "Appearance slider CNTL resource",
    "little_arrows": "Appearance little-arrows CNTL resource",
    "disclosure": "Appearance disclosure CNTL resource",
    "image_well": "Appearance image-well CNTL resource",
    "system_icon": "icon CNTL resource + Icon Services",
    "text_area": "TextEdit fallback",
    "quickdraw_canvas": "QuickDraw offscreen GWorld + CopyBits",
    "icon": "QuickDraw original planning glyph",
}

PALETTES = {
    1: [(255, 255, 255), (0, 0, 0)],
    4: [
        (255, 255, 255), (0, 0, 0), (204, 204, 204), (136, 136, 136),
        (68, 68, 68), (255, 0, 0), (0, 128, 0), (0, 0, 255),
        (255, 255, 0), (0, 255, 255), (255, 0, 255), (128, 0, 0),
        (0, 96, 0), (0, 0, 128), (128, 96, 0), (128, 0, 128),
    ],
    8: [
        (255, 255, 255), (0, 0, 0), (221, 221, 221), (187, 187, 187),
        (153, 153, 153), (102, 102, 102), (51, 51, 51), (0, 102, 204),
        (40, 142, 74), (224, 156, 32), (190, 48, 48), (103, 78, 167),
        (124, 158, 240),
    ] + [(i, i, i) for i in range(13, 256)],
}


def component_status(target, component_type):
    if component_type in BASE_COMPONENT_STATUS:
        if target == "platinum-carbonlib" and component_type in {
            "button", "checkbox", "radio", "field", "group", "scrollbar"
        }:
            return "native-api-route"
        return BASE_COMPONENT_STATUS[component_type]
    if component_type in {"tabs", "progress"}:
        return "native-api-route" if target == "platinum-carbonlib" else (
            "native-resource-route" if target == "platinum-toolbox" else "custom-required"
        )
    if component_type == "databrowser":
        return "native-api-route" if target == "platinum-carbonlib" else "unsupported"
    if component_type in {"bevel_button", "placard"}:
        if target == "platinum-carbonlib":
            return "native-api-route"
        if target == "platinum-toolbox":
            return "native-resource-route"
        return "unsupported"
    if component_type in {
        "popup", "slider", "little_arrows", "disclosure", "image_well",
        "system_icon",
    }:
        if target == "platinum-carbonlib":
            return "native-api-route"
        if target == "platinum-toolbox":
            return "native-resource-route"
        return "unsupported"
    if component_type == "text_area":
        return "native-api-route" if target == "platinum-carbonlib" else "unsupported"
    return "unsupported"


def component_primitive(target, component_type):
    if target == "platinum-carbonlib":
        return CARBON_PRIMITIVES.get(component_type, "unresolved")
    return RESOURCE_PRIMITIVES.get(component_type, "unresolved")
