---
page_id: dev-arch-updating
title: Host-owned updates
description: How the host publishes exact classic artifacts and the PowerPC guest verifies, installs, and activates them.
doc_type: explanation
audience: developer
lifecycle: current
authority: [contract/asyncapi.yaml, contract/product_version.h, contract/resident_version.h, docs/resident-components.md]
source_dependencies: [RELEASING.md, .github/repository-policy.json, contract/asyncapi.yaml, contract/product_version.h, contract/resident_version.h, tools/write-update-manifest.py, tools/product-version-gate, tools/ext-bake-gate, tools/sync-main, tools/github-policy-check, now-guest-ppc/cmake/buildstamp.cmake, ext/cmake/build_identity.cmake, now-host/Sources/Host/UpdateProvider.swift, now-host/Sources/Host/GuestListener.swift, now-host/Sources/Host/ConnectionsModel.swift, now-host/Sources/Host/ConnectionsModuleView.swift, now-guest-ppc/src/update, now-guest-ppc/src/core/wire.c]
media_ids: []
last_verified: 2026-08-12
---

<!-- now-doc-provenance: generated reviewed=false -->

# Host-owned updates

The modern host is the only update provider. The guest never searches the
internet, chooses a channel, or accepts a host-selected replacement without a
request. Publication and installation are separate decisions.

```mermaid
sequenceDiagram
  participant H as macOS host
  participant G as PowerPC guest
  participant D as Classic disk
  H->>H: Validate sidecar, byte count, and SHA-256
  H->>G: update.offer(version, build, digest, trust)
  G->>G: Compare release version and exact build
  G->>H: update.request(component, exact build, digest)
  H->>G: file.offer + MacBinary bulk stream
  G->>G: Verify SHA-256 and Finder identity
  G->>D: Move old item to Trash; put replacement at canonical path
  G->>H: update.result
  alt application
    G->>G: Stay connected and report quit/relaunch required
  else Extension
    G->>G: Report restart required
  end
```

Text equivalent: the host validates its catalog before sending an offer; the
guest compares exact identity and requests one build; the host transfers that
MacBinary through the existing file lane; the guest verifies the stream and
Finder identity before replacing files. It then reports the outcome and tells
the person either to quit and relaunch the application or to restart before
the Extension becomes active.

## Publication unit

`tools/write-update-manifest.py` writes an adjacent
`.now-update.json` sidecar for each canonical MacBinary. It contains the
component, release version, exact build identity, byte count, SHA-256, channel,
and signature state. A loose artifact without a valid sidecar may still serve
onboarding, but `UpdateProvider` will not advertise it. The provider reads the
normal onboarding catalog, then recomputes byte count and SHA-256 before every
catalog snapshot becomes an offer.

`contract/product_version.h` owns the host/PPC application-family release
version. The classic `vers` resource, Swift identity, Xcode marketing version,
and fallback host `Info.plist` remain checked copies because their build systems
cannot all consume the same C macro. Application build identity is a full
SHA-256 over stable paths, each build input's SHA-256, and the compiler/toolchain
profile. It contains no wall clock, so the same inputs are idempotent across
worktrees. The Extension uses the same scheme for publication while retaining
the first 160 bits in its shipped in-memory ABI. NOW-68K retains its separate
experimental deployment version.

The wire has a third identity: `info.x-contract-revision` in AsyncAPI, shared
through `contract/wire_limits.h`. It gates compatibility during `hello` and is
not a product or Extension release number. AsyncAPI's own `info.version`
versions the contract document; it may happen to equal a product release but no
gate treats that equality as an invariant.

Release version answers product ordering and display. Deterministic build
identity answers which source/toolchain inputs; artifact SHA-256 answers which
exact MacBinary bytes. A host development build with the same version and a
different build ID is therefore a real offer rather than “already current.” An older host
artifact is identified as older and cannot arm Install; a version difference is
not permission to downgrade.

`tools/product-version-gate` keeps all checked product-version copies coherent
and prevents rollback. Main is an integration boundary, not automatically a
release boundary: two serial branches may land at one release version because
their content-derived build IDs do not depend on landing order. An intentional
release advances the version and qualifies numbered candidates from a
`release/vVERSION` branch. Candidate artifacts use annotated
`now-product-vVERSION-rc.N` or `now-extension-vVERSION-rc.N` tags and carry a
`candidate` update channel. Accepted candidate revisions receive final
annotated tags without the suffix. Every annotation pins the component, full
build ID, and artifact SHA-256. `write-update-manifest.py` refuses an
unnumbered candidate, moved or lightweight tag, dirty source tree, or different
bytes under that publication identity. [RELEASING.md](../../../RELEASING.md)
owns the branch, qualification, and promotion procedure. A working branch
lands only through GitHub's protected pull-request path. After GitHub accepts
it, `tools/sync-main` fast-forwards the public clone's local main to the exact
fetched `origin/main`; `tools/main-ref-policy` and the reference-transaction
hook refuse any other local-main target or rollback, while the pre-push hook
refuses direct remote-main updates. `tools/github-policy-check` compares the
live ruleset with its committed policy. Extension build inputs still follow the
parallel non-rollback and exact shared-bake gate.

## Transfer and install

The guest requests the exact offered build and artifact SHA-256. The host
requires both to still name its published artifact before serving it through
the existing `file.offer` and bulk lane. Update
receives cannot resume, cannot choose an arbitrary destination, and must match
the pending component, request id, exact offer, byte count, and digest.

The SHA-256 covers the raw MacBinary stream. After the existing receiver has
decoded and committed the classic file, the installer also checks Finder
identity: `APPL/NOWo` for the application and `INIT/NOWx` for the Extension.

- The application receives a collision-free recovery name, moves into that
  volume's Trash, and leaves the canonical pathname free for the verified
  replacement. The old process stays connected from the trashed file long
  enough to report `relaunch-required`; the person quits it and launches the
  canonical application again.
- The Extension follows the same Trash-first replacement. Activation is never
  claimed until the person restarts the classic Mac. If any filesystem step
  fails, the installer restores the prior canonical name when possible and
  reports where the recoverable old item remains when it cannot.

The guest compares the active table's resident major/minor with the version it
compiled against and warns when they differ. Capability bits, not version, still
govern which resident planes the application may use.

## Trust boundary

SHA-256 is integrity, not signing. Every generated manifest currently says
`signed: false`; the guest labels the offer unsigned and requires an explicit
human confirmation. That confirmation may be the guest Connections button or
one of the host Connections page's separate application/Extension replacement
buttons. The latter sends `hostApproved:true`; absent or false remains refused.
This is an application-level authorization on the trusted-LAN wire, not proof
of who sent a frame: a hostile raw peer can forge it because the protocol is
plaintext and unauthenticated. A future release-signing design needs a pinned
trust root, key rotation and recovery policy before `signed` can become true.

The underlying classic wire remains plaintext and unauthenticated. Artifact
signing will authenticate release bytes, not make the transport safe for an
untrusted network.

## Verification boundary

Native tests cover SHA-256, exact-build comparison, trust labels, provider
validation, contract round trips, and critical source ordering. Guest
cross-builds prove the Carbon and Toolbox APIs compile. Emulator acceptance
must still prove Trash-first replacement, a manual application relaunch,
Extension replacement, restart activation, and rollback. Only physical
hardware can make the result metal-verified.
