from pathlib import Path

root = Path(__file__).resolve().parents[2]
adapter = (root / "ext/src/now_semantic.c").read_text()
core = (root / "ext/src/now_ext.c").read_text()

for unavailable in (
    "AcquireRootMenu(",
    "GetMenuItemHierarchicalMenu(",
    "ReleaseMenu(",
    "IsMenuItemEnabled(",
    "GetControlKind(",
):
    assert unavailable not in adapter, f"flat INIT reintroduced unavailable {unavailable}"

assert "return kNowPeekSemanticStatusUnsupported;" in adapter
assert "kControlKindTag" in adapter
assert "kControlListBoxListHandleTag" in adapter
assert "kControlListBoxLDEFTag" not in adapter
assert "ldef !=" not in adapter
assert "kNowPeekTableCapAnchors | kNowPeekTableCapTree" in core
assert "table->semantic_format = kNowPeekSemanticFormatV2" in core
print("semantic flat-INIT ABI guard: ok")
