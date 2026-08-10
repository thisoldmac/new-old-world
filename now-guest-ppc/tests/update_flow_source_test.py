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
main = (ROOT / "now-guest-ppc/src/main.c").read_text()

# A remote command must not silently spend the local confirmation the
# Connections page collected. Mutating false to true reopens exactly that gap.
assert "now_wire_update_request(component, false" in commands
ordered(connection, "now_confirm(\"Install unsigned update?\"",
        "now_wire_update_request(component, true")
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

# Finder identity is checked before either component is exchanged. The old
# resident is made non-INIT after a successful exchange so it cannot double
# load on the next boot.
ordered(install, "finder_identity(staged, 'APPL', 'NOWo')",
        "FSpExchangeFiles(staged, &current)")
ordered(install, "finder_identity(staged, 'INIT', 'NOWx')",
        "FSpExchangeFiles(staged, &current)",
        "if (err == noErr) make_inert(staged)")

# Relaunch happens after the application's normal teardown and log close, not
# from inside the nested receive callback.
ordered(main, "now_log_close();", "now_update_relaunch();")
