#!/usr/bin/env python3
"""Every AESend output and partial document event has bounded ownership."""

from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
sources = list((REPO / "now-guest-ppc/src").rglob("*.c"))
sources += list((REPO / "now-guest-68k/src").rglob("*.c"))
text = "\n".join(path.read_text() for path in sources)

assert text.count("AESend(") == text.count("AEDisposeDesc(&reply)"), (
    "every AESend reply descriptor must be initialized and disposed, even "
    "for kAENoReply"
)

fileshare = (REPO / "now-guest-ppc/src/files/fileshare.c").read_text()
for declaration in (
    "AppleEvent event = { typeNull, NULL };",
    "AppleEvent reply = { typeNull, NULL };",
    "AEAddressDesc target = { typeNull, NULL };",
    "AEDescList docs = { typeNull, NULL };",
):
    assert declaration in fileshare

cleanup = """AEDisposeDesc(&reply);
    AEDisposeDesc(&docs);
    AEDisposeDesc(&event);
    AEDisposeDesc(&target);"""
assert cleanup in fileshare, (
    "Finder reveal must release every descriptor after any construction failure"
)

print("AppleEvent send and partial-construction descriptors are failure-atomic")
