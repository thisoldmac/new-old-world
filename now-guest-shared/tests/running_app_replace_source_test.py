#!/usr/bin/env python3
"""Pins the Finder-style running-application replacement on both guests.

The behavior is Toolbox-bound, so the host compiler cannot execute it. This
test instead guards the cross-guest control-flow and the one shared receipt
field. It has deliberately narrow assertions: both implementations must test
fBsyErr only for APPL, move a same-named Trash occupant aside rather than
renaming the running application, and tell the host that a relaunch is needed.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PPC = (ROOT / "now-guest-ppc/src/files/fileshare.c").read_text()
PPC_WIRE = (ROOT / "now-guest-ppc/src/core/wire.c").read_text()
K68 = (ROOT / "now-guest-68k/src/files/n68_putfile.c").read_text()
K68_WIRE = (ROOT / "now-guest-68k/src/core/wire68.c").read_text()
CONTRACT = (ROOT / "contract/asyncapi.yaml").read_text()


def ordered(source: str, *needles: str) -> None:
    cursor = 0
    for needle in needles:
        found = source.find(needle, cursor)
        assert found >= 0, f"missing or out of order: {needle}"
        cursor = found + len(needle)


ordered(
    PPC,
    "err = FSpDelete(&rx->final);",
    "err == fBsyErr && spec_is_application(&rx->final)",
    "move_busy_named(&rx->final, trash_dir",
    "rx->relaunch_required = true;",
    "err = FSpRename(&rx->temp, final_name);",
)
move_start = PPC.index(
    "static int move_busy_named(FSSpec *spec, long to_dir,\n"
    "                           const unsigned char *desired,\n"
    "                           Str255 out_final)\n{",
    PPC.index("static void free_name"),
)
move_end = PPC.index("\n}\n", move_start)
ppc_move = PPC[move_start:move_end]
ordered(
    ppc_move,
    "FSMakeFSSpec(spec->vRefNum, to_dir, desired, &collision) == noErr",
    "free_name_in_folder(spec->vRefNum, to_dir, desired, available);",
    "FSpRename(&collision, available)",
    "cat_move(spec, to_dir)",
)
ordered(
    K68,
    "old_info.fdType == 'APPL'",
    "err = FSpDelete(&pf->final);",
    "err == fBsyErr && old_is_application",
    "move_running_application_to_trash(",
    "pf->relaunch_required = 1;",
    "err = FSpRename(&pf->temp, final_name);",
)
assert "FSpRename(&collision, moving)" in K68
assert "FSpRename(&pf->final, moving)" not in K68
collision_start = K68.index("if (FSMakeFSSpec(trash_vref, trash_dir, moving")
collision_end = K68.index("err = FSpRename(&collision, moving);",
                          collision_start)
assert "pf->final.parID" not in K68[collision_start:collision_end]
for source in (PPC_WIRE, K68_WIRE):
    assert 'relaunchRequired\\\":true' in source
assert "relaunchRequired:" in CONTRACT
assert "running application to the" in CONTRACT
assert "person quits and relaunches it" in CONTRACT

print("running_app_replace_source: ok")
