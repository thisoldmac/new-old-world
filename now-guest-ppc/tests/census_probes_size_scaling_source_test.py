"""Pin gather_volumes() and the ATA drive-size line onto census_size_mib().

H13 scaled the Hardware overview page's Storage block (gather_overview,
census_size_mib) but left two code-identical call sites printing raw MB:
the standalone Volumes probe (gather_volumes) and the ATA probe's
drive-size line. Both format the same kind of number the overview already
scales, so this pins both onto the same formatter rather than letting a
new sibling function reintroduce the same raw-MB gap.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
probes = (ROOT / "now-guest-ppc/src/census/census_probes.c").read_text()


def function_body(name):
    start = probes.index("static void " + name + "(")
    # Walk to the matching close brace by counting braces from the first
    # '{' after the signature.
    open_brace = probes.index("{", start)
    depth = 0
    i = open_brace
    while True:
        ch = probes[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return probes[open_brace:i + 1]
        i += 1


volumes_body = function_body("gather_volumes")
assert volumes_body.count("census_size_mib(") == 2, (
    "gather_volumes must scale both the total and free readings through "
    "census_size_mib(), the same formatter gather_overview's Storage "
    "block uses"
)
assert '"%lu MB, %lu MB free"' not in volumes_body, (
    "the volumes line must not go back to raw unscaled MB"
)

ata_body = function_body("gather_ata")
assert "census_size_mib(" in ata_body, (
    "the ATA drive-size line must scale through census_size_mib(), like "
    "the volumes and overview Storage lines"
)
assert '"%.28s, %lu MB, fw %.8s"' not in ata_body, (
    "the ATA drive-size line must not go back to raw unscaled MB"
)
