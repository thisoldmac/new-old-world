---
page_id: verification-safety-explanation
title: Verification and safety
description: Read NOW's Builds, Tested, Emulator-verified, and Metal-verified labels without turning one rung into another.
doc_type: explanation
audience: user
lifecycle: current
authority: [AGENTS.md, SECURITY.md]
source_dependencies: [AGENTS.md, SECURITY.md, scripts/test-all]
media_ids: []
last_verified: 2026-08-09
---

# Verification and safety

NOW uses evidence labels as a controlled vocabulary:

- **Builds** means the source compiled. It proves no behavior.
- **Tested** means relevant suites passed on the development machine.
- **Emulator-verified** means someone observed the behavior in a named virtual
  classic Macintosh rig.
- **Metal-verified** means someone observed it on the named physical machine.

A higher label is never inferred from a lower one. A feature can be
metal-verified on PowerPC and unavailable on 68K, or tested in the host while a
real classic path remains unverified.

Safety has a separate boundary. The guest wire is plaintext TCP with no peer
authentication and the host listens for a guest connection. Use a trusted LAN,
do not forward the port, and treat connected peers as able to exercise the
capabilities you grant. Shared folders bound ordinary file access, while the
MCP and Mirror surfaces add their own consent ceilings.

The concise release view is [Current limitations](../reference/limitations.md).
