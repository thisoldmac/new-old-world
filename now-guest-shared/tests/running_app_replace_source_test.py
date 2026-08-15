#!/usr/bin/env python3
"""Pins the Finder-style running-application replacement on both guests.

The behavior is Toolbox-bound, so the host compiler cannot execute it. This
test instead guards the cross-guest control-flow and the one shared receipt
field. It has deliberately narrow assertions: both implementations must test
fBsyErr only for APPL, move a same-named Trash occupant aside rather than
renaming the running application, and tell the host that a relaunch is needed.

The PPC guest has TWO callers of that same "move a live-named spec into a
folder without renaming it" primitive — the ordinary Files-share overwrite
(`fileshare.c`) and the in-place updater (`update_install.c`), which
independently re-derived and broke the fix on 2026-08-14 (034 H4: it renamed
the running app before moving it, the exact operation this test already
existed to rule out). They now share one implementation
(`files/trash_move.c`), so this test checks the shared body once and checks
each caller only for what would be the regression at ITS call site: a
literal rename of the still-running spec.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PPC = (ROOT / "now-guest-ppc/src/files/fileshare.c").read_text()
PPC_TRASH = (ROOT / "now-guest-ppc/src/files/trash_move.c").read_text()
PPC_UPDATE = (ROOT / "now-guest-ppc/src/update/update_install.c").read_text()
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


def function_body(source: str, signature: str, after: str = "") -> str:
    start = source.index(signature, source.index(after) if after else 0)
    end = source.index("\n}\n", start)
    return source[start:end]


ordered(
    PPC,
    "err = FSpDelete(&rx->final);",
    "err == fBsyErr && spec_is_application(&rx->final)",
    "move_busy_named(&rx->final, trash_dir",
    "rx->relaunch_required = true;",
    "err = FSpRename(&rx->temp, final_name);",
)
# The shared primitive: evict any Trash occupant sitting on the wanted name
# BEFORE moving the (possibly still-running) spec, and never rename the
# spec itself — the exact order `fileshare.c` and `update_install.c` both
# depend on to avoid fBsyErr.
ppc_trash_move = function_body(
    PPC_TRASH, "OSErr now_trash_move_busy(FSSpec *spec, long to_dir)\n{")
ordered(
    ppc_trash_move,
    "FSMakeFSSpec(spec->vRefNum, to_dir, spec->name, &collision) == noErr",
    "free_name_in_folder(spec->vRefNum, to_dir, spec->name, available);",
    "FSpRename(&collision, available)",
    "cat_move(spec, to_dir)",
)
assert "FSpRename(spec," not in ppc_trash_move, (
    "the shared primitive must never rename the spec it is moving")
# fileshare.c's own move_busy_named now delegates rather than re-deriving.
ppc_move = function_body(
    PPC,
    "static int move_busy_named(FSSpec *spec, long to_dir,\n"
    "                           const unsigned char *desired,\n"
    "                           Str255 out_final)\n{",
    after="static void free_name(")
assert "now_trash_move_busy(spec, to_dir)" in ppc_move
assert "FSpRename(spec," not in ppc_move
# update_install.c: the 2026-08-14 regression this test was extended for.
# It used to FSpRename the live application's own spec to a recoverable
# "X old" name before moving it — exactly the fBsyErr operation
# `move_busy_named`'s own comment already named. It now uses the shared
# primitive on both the forward move and the rollback, under the item's
# unchanged original name.
ppc_move_old = function_body(
    PPC_UPDATE,
    "static int move_old_to_trash(FSSpec *spec, Str63 original_name,\n"
    "                             long *original_dir, char *reason, long cap)\n{")
assert "now_trash_move_busy(spec, trash_dir)" in ppc_move_old
assert "FSpRename(spec," not in ppc_move_old
ppc_restore = function_body(
    PPC_UPDATE,
    "static int restore_from_trash(FSSpec *old, long original_dir,\n"
    "                              const Str63 original_name)\n{")
assert "now_trash_move_busy(old, original_dir)" in ppc_restore
assert "FSpRename(old," not in ppc_restore
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
