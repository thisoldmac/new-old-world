#!/usr/bin/env python3
"""Pin the Workshop's one-definition/one-instance composition seam."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"
window = (SRC / "workshop/workshop_window.c").read_text()
sidebar = (SRC / "workshop/workshop_sidebar.c").read_text()
header = (SRC / "workshop/workshop_module.h").read_text()
# The page ids live in their own Toolbox-free header so workshop_order.c
# (and its native test) can read them; the pinning below follows them
# there rather than losing sight of them.
ids = (SRC / "workshop/workshop_module_ids.h").read_text()
assert '#include "workshop_module_ids.h"' in header, (
    "workshop_module.h must still carry the page ids to its includers"
)
registry = (SRC / "workshop/workshop_registry.c").read_text()
network = (SRC / "network/network_module_definition.c").read_text()
cmake = (ROOT / "CMakeLists.txt").read_text()

for old_authority in ("g_ops", "g_created", "k_module_info"):
    assert old_authority not in window, (
        f"Workshop window regained parallel authority {old_authority}"
    )
assert not re.search(r'#include "[^"]+_module\.h"', window), (
    "Workshop window must depend on the registry, not every module header"
)
assert "WorkshopModuleInstance g_modules" in window
assert "workshop_registry_prepare(g_modules" in window
assert "now_workshop_ensure_constructed(&instance->created" in window

assert "k_rows" not in sidebar, "sidebar metadata must come from definitions"
assert "workshop_module_definition(module)" in sidebar

expected_pages = {
    "kWorkshopScreenshots": 1,
    "kWorkshopFiles": 2,
    "kWorkshopConsole": 3,
    "kWorkshopProcesses": 4,
    "kWorkshopHardware": 5,
    "kWorkshopSoftware": 6,
    "kWorkshopMCP": 7,
    "kWorkshopDiagnostics": 8,
    "kWorkshopNetworking": 9,
    "kWorkshopCloud": 10,
    "kWorkshopChat": 11,
    "kWorkshopMirror": 12,
    "kWorkshopDevelopment": 13,
    "kWorkshopWeb": 14,
    "kWorkshopPreferences": 15,
    "kWorkshopLogs": 16,
    "kWorkshopConnection": 17,
}
declared = {
    name: int(value)
    for name, value in re.findall(r"\b(kWorkshop[A-Za-z]+)\s*=\s*(\d+)", ids)
    if name in expected_pages
}
assert declared == expected_pages, (
    f"persisted Workshop page IDs moved: {declared} != {expected_pages}"
)

assert "switch (page_id)" not in registry, (
    "adding a Workshop module must not grow a central dispatch switch"
)
catalog = registry[
    registry.index("k_module_definitions[]"):
    registry.index("const WorkshopModuleDefinition *workshop_module_definition")
]
factories = re.findall(r"\b([a-z][a-z0-9_]*)_module_definition\s*,", catalog)
assert len(factories) == len(expected_pages), (
    "registry must compose exactly one factory for every persisted page"
)
assert len(factories) == len(set(factories)), (
    "registry must not compose one module factory twice"
)
assert "definition->page_id == page_id" in registry, (
    "the registry must reject a definition filed under the wrong page id"
)

for token in (
    "kWorkshopNetworking",
    '"networking"',
    '"Networking"',
    '"Link, address and ports"',
    "139",
    "kWorkshopModuleTierCore",
    "network_module_ops",
):
    assert token in network, f"Networking definition lost {token}"
assert "network_module_definition," in registry

for source in (
    "src/workshop/workshop_registry.c",
    "src/network/network_module_definition.c",
):
    assert source in cmake, f"PowerPC target does not compile {source}"

print("Workshop registry owns one static definition/instance seam")
