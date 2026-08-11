#!/usr/bin/env python3
"""Keep fallible Data Browser setup from becoming a partial live control."""

from pathlib import Path
import re


SRC = Path(__file__).resolve().parents[1] / "src"
files = sorted(SRC.rglob("*.c"))

unchecked_callbacks = []
unchecked_columns = []
for path in files:
    text = path.read_text()
    if re.search(r"(?m)^\s*SetDataBrowserCallbacks\s*\(", text):
        unchecked_callbacks.append(path.relative_to(SRC))
    if re.search(r"(?m)^\s*add_column\s*\(", text):
        unchecked_columns.append(path.relative_to(SRC))

assert not unchecked_callbacks, (
    "Data Browser callback installation is fallible and must be checked: "
    + ", ".join(map(str, unchecked_callbacks))
)
assert not unchecked_columns, (
    "Data Browser column installation is fallible and must be checked: "
    + ", ".join(map(str, unchecked_columns))
)

for relative in (
    "files/files_browser_view.c",
    "processes/processes_module.c",
    "software/software_module.c",
):
    text = (SRC / relative).read_text()
    assert "discard_browser" in text, (
        f"{relative} must tear down a partially constructed browser"
    )

print("Data Browser setup checks errors and discards partial controls")
