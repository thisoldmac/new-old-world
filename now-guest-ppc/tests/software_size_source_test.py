#!/usr/bin/env python3
"""Pin division-before-addition at Classic signed-long size seams."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
software = (ROOT / "src/software/software.c").read_text()
module = (ROOT / "src/software/software_module.c").read_text()
layout = (ROOT / "src/software/software_layout.c").read_text()
files_browser = (ROOT / "src/files/files_browser_view.c").read_text()
files_pull = (ROOT / "src/files/files_pull.c").read_text()
cloud_drive = (ROOT / "src/cloud/cloud_drive_view.c").read_text()
cloud_model = (ROOT / "src/cloud/cloud_model.c").read_text()
guest_68k = (ROOT.parent / "now-guest-68k/src/software/n68_swenum.c").read_text()

assert software.count("sw_fork_size_k(pb.hFileInfo.ioFlLgLen,") == 2, (
    "both Software catalog paths must use the overflow-free fork sum"
)
assert "ioFlLgLen\n                       + pb.hFileInfo.ioFlRLgLen" not in software, (
    "Classic signed fork lengths must not be added before division"
)
assert "size_k * 1024" not in module, (
    "stored kilobytes must not be expanded into an overflowing signed long"
)
assert "data_k = (unsigned long)data_bytes / 1024UL" in layout
assert "resource_k = (unsigned long)resource_bytes / 1024UL" in layout
assert "row->data_bytes + row->rsrc_bytes" not in files_browser
assert "row->data_bytes + row->rsrc_bytes" not in cloud_drive
assert "bytes + 1023" not in files_pull
assert "received + 1023" not in cloud_model
assert "expected + 1023" not in cloud_model
assert "ioFlLgLen + pb->hFileInfo.ioFlRLgLen" not in guest_68k

print("Software size arithmetic divides before target-width additions")
