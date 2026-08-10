---
page_id: two-macs-explanation
title: Two Macs, one contract
description: Why NOW keeps native applications on both machines and makes their versioned wire contract the shared source of truth.
doc_type: explanation
audience: user
lifecycle: current
authority: [docs/architecture.md, contract/asyncapi.yaml]
source_dependencies: [docs/architecture.md, contract/asyncapi.yaml]
media_ids: []
last_verified: 2026-08-09
---

# Two Macs, one contract

NOW is not a modern application remotely painting a classic-looking client.
The macOS host and each classic guest are native applications for their own
systems. A modern file browser should feel like macOS; the Workshop should feel
like Mac OS 9; NOW-68K should respect the memory and UI model of System 7.1.

The shared object is the wire contract. It defines message shape, symmetry,
limits, and refusal vocabulary. Whichever side receives a request serves its
own machine's share. This is why Files, Processes, and Console can have two
human faces with one behavior behind each guest's local and wire entry points.

The separation also keeps failure honest. A revision mismatch is refused at
the handshake. An unavailable module is stated as an asymmetry. The absence of
the optional resident removes capabilities rather than making the entire
product unavailable.

For protocol details, see the developer guide's
[wire contract](../../developer-guide/architecture/wire-contract.md).
