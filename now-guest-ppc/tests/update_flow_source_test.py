"""Pin the updater's trust and install ordering where Toolbox tests cannot run."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def ordered(text: str, *pieces: str) -> None:
    cursor = -1
    for piece in pieces:
        found = text.find(piece, cursor + 1)
        assert found >= 0, f"missing updater seam: {piece}"
        assert found > cursor, f"updater seam is out of order: {piece}"
        cursor = found


wire = (ROOT / "now-guest-ppc/src/core/wire.c").read_text()
commands = (ROOT / "now-guest-ppc/src/commands/commands.c").read_text()
connection = (
    ROOT / "now-guest-ppc/src/connection/connection_module.c"
).read_text()
install = (ROOT / "now-guest-ppc/src/update/update_install.c").read_text()
activation = (
    ROOT / "now-guest-ppc/src/update/update_activation.c"
).read_text()
prefs = (ROOT / "now-guest-ppc/src/core/prefs.c").read_text()
main = (ROOT / "now-guest-ppc/src/main.c").read_text()

# A bare remote command must not stand in for consent. The only remote path
# that may install an unsigned development artifact carries the native host
# button's explicit Boolean approval; the guest's own button still confirms
# locally. Removing the parse or hard-coding true breaks this distinction.
assert 'now_json_find_bool(request_json, "hostApproved", 0)' in commands
assert "now_wire_update_request(component, host_approved" in commands
ordered(connection, "now_confirm(\"Install unsigned update?\"",
        "now_wire_update_request(component, true")
assert r'\"sha256\":\"%s\"' in wire
ordered(wire, "if (!offer.signed_artifact && !allow_unsigned)",
        "++g.offer_seq", "g_update.pending = true")
assert "offer.signed_artifact = 0;" in wire
assert 'now_json_find_bool(reply, "signed"' not in wire

# Integrity is over the exact incoming MacBinary stream. Installation can
# occur only after the digest comparison and the transactional receive finish.
ordered(wire, "now_sha256_update(&g_put.update_sha, bytes, len)",
        "now_sha256_final(&g_put.update_sha, digest)",
        "strcmp(got, g_put.update_sha256)",
        "now_files_receive_finish(&g_put.rx)",
        "now_update_install(g_put.update_component")

# 034 H4: cancelling an update mid-download -- whether the person presses
# Cancel at the host (file.end ok:false) or at the guest console
# (now_wire_put_cancel) -- must free g_update.pending the same way every
# OTHER way an update transfer ends already does. Left uncleared,
# run_update's own "already pending" guard (above) refuses every later
# attempt until the app relaunches: the guest half of what a sane
# post-cancel state means.
put_abort_start = wire.index("static void put_abort(const char *code")
put_abort_end = wire.index("\n}\n", put_abort_start)
put_abort_body = wire[put_abort_start:put_abort_end]
ordered(put_abort_body, "if (g_put.update)", "g_update.pending = false;")

# Finder identity is checked before either component is installed. The old
# item moves to that volume's Trash under its OWN unchanged name before the
# verified staged item takes the canonical name -- 2026-08-14 (034 H4): this
# used to rename the old item to a collision-free recovery name first, which
# is the exact fBsyErr operation fileshare.c's move_busy_named was already
# hardened against (renaming a still-running spec does not succeed reliably
# on every system Finder replacement does). There is no exchange: the
# running app deliberately remains alive from the trashed file long enough
# to report that a relaunch is required.
ordered(install, "finder_identity(staged, 'APPL', 'NOWo')",
        'replace_to_trash(staged, &current, "application"')
ordered(install, "finder_identity(staged, 'INIT', 'NOWx')",
        'replace_to_trash(staged, &current, "NOW Extension"')
ordered(install, "FindFolder(spec->vRefNum, kTrashFolderType",
        "now_trash_move_busy(spec, trash_dir)")
assert "FSpRename(spec," not in install, (
    "the live spec must never be renamed -- that is what returns fBsyErr")
ordered(install, "move_old_to_trash(&old", "FSpRename(&replacement",
        "restore_from_trash(&old")
assert "FSpExchangeFiles" not in install

# The update callback never quits or relaunches the running application. It
# reports the required human action on the existing connection instead.
assert "now_update_relaunch" not in main
assert '"relaunch-required"' in wire
assert "g_update.relaunch_required = true;" in wire
assert "now_wire_update_relaunch_required()" in connection
assert "Application installed - quit and relaunch NOW" in connection

# A successful extension exchange ends in a stable restart-required state,
# not the stale "Downloading..." sentence or another enabled install button.
ordered(wire, "now_update_install(g_put.update_component",
        "g_update.restart_required = true;",
        "g_update.pending = false;")
ordered(wire, "now_update_activation_record(g_update.build)",
        "now_update_install(g_put.update_component")
assert "now_update_activation_clear()" in wire
ordered(activation, "now_update_current_identity(kNowUpdateExtension",
        "now_update_extension_pending_activation(",
        "prefs->pending_extension_build[0] = '\\0';",
        "now_prefs_save(prefs)")
# The continuity branch already owns V25 for bounded launch-log retention.
# Activation receipts must extend that record instead of reusing the same
# format number with a different binary layout. A later slice (Workshop
# open/closed persistence) owns V27 on top of this one, so the pin here
# checks the V26 layer nests unchanged rather than pinning the top-level
# format number, which the later slice legitimately moved on.
assert "PrefsRecordV25 v25;               /* format = 26 */" in prefs
assert "PrefsRecordV26 v26;               /* format = 27 */" in prefs
assert "pending_extension_build" in prefs
ordered(wire, "now_prefs_load(&prefs);",
        "g_update.restart_required = now_update_activation_reconcile(&prefs);")
assert "update_transfer_reset();" in wire
assert "now_wire_update_restart_required()" in connection
assert "Extension installed - restart this Mac" in connection
assert "Extension installed. Restart this Mac to activate it." in connection
