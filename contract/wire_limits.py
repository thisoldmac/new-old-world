"""The frame format's numbers, for the Python side of the house.

The Python sibling of `contract/wire_limits.h`, and it lives in the same
directory for one reason: a person bumping the revision in the header
sees this file on the next line of the same listing. The drift this
replaces went the other way — the number moved in `wire_limits.h`, the
guests and the host followed it because they *compile* it, and five
Python harnesses that only ever declared it by hand did not.

WHAT THIS IS NOT: a parser. Nothing here reads the header or the
contract at run time. `scripts/probes/nowwire.py` argued, correctly,
that a probe which silently followed a changed constant would report
numbers from a wire it did not describe — a probe is not part of the
build and must keep saying what it thinks it is speaking. So these stay
DECLARED, and a human still bumps them deliberately.

What changes is only that the declaration happens once instead of five
times, and that divergence is no longer something only a human notices:
`WireLimitsAgreementTests` reads this file, `wire_limits.h` and
`contract/asyncapi.yaml`'s `info.x-contract-revision` and fails when any
two disagree. It also fails when a harness reintroduces its own literal.
A copy that is *checked* is not a second source of truth; a copy that is
not is exactly how this drifted.

Import it from anywhere in the tree by putting this directory on the
path — the harnesses are scripts, not a package:

    sys.path.insert(0, os.path.join(REPO_ROOT, "contract"))
    from wire_limits import WIRE_CONTRACT_REVISION
"""

# contract/asyncapi.yaml, info.x-contract-revision, and
# NOW_WIRE_CONTRACT_REVISION in wire_limits.h. This gates the hello
# handshake: unequal revisions refuse. A harness stale here is not a
# cosmetic wrong number — NOW-68K tears the connection down and redials
# forever, and the probe sees a machine that will not talk to it.
WIRE_CONTRACT_REVISION = 2

# Frame header, big-endian, 8 bytes: channel u8, flags u8, transfer u16,
# length u32. See wire_limits.h for why both guests build these bytes
# explicitly rather than overlaying a struct.
FRAME_HEADER_BYTES = 8
CHANNEL_CONTROL = 0
CHANNEL_BULK = 1
FLAG_END = 0x01

# Max payload bytes of ANY frame. Over this is a protocol violation on
# either channel.
MAX_PAYLOAD = 32768

# Deliberately NOT from wire_limits.h, which explains at length why the
# 4096-byte CONTROL cap is stated by each guest in its own terms instead
# of hoisted. Restated here so a harness has the number without having to
# decide which guest's description of it is the contract's.
MAX_CONTROL_PAYLOAD = 4096
