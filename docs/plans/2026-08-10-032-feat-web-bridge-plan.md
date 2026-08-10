---
title: Web bridge and classic-browser proxy plan
type: plan
date: 2026-08-10
status: implemented-direct-baseline
search:
  exclude: true
---

# Web bridge and classic-browser proxy plan

## Implementation receipt

The Direct baseline is implemented on `codex/web-proxy`: a bundled NOW-owned
helper, host supervision and Web module, a PowerPC Workshop page with migrated
preferences, Classilla/MacWeb/Generic profiles, Compatible/Reader/AI lenses,
Wikipedia and Reddit handlers, and an explicit adapter for the preserved local
MLX model. The helper and host use the selected modern-Mac listener address;
the PPC page derives its address from Connection (`10.0.2.2` under this
repository's QEMU user network, the host Mac's LAN address on hardware).

Workstream D did not pass its prerequisite because no target listener probe was
run in this source-only implementation session. Consequently no guest-local
relay contract, Open Transport listener, or MacTCP listener was introduced.
NOW-68K remains able to use Direct mode through MacWeb's own proxy settings but
has no Web configuration surface. Those are retained as explicit follow-up
work rather than inferred from successful compilation.

## Objective

Make the modern web usable from a browser already installed on a classic Mac.
The macOS host owns TLS, contemporary JavaScript, modern image formats and the
optional local layout model. It returns bounded, navigable HTML appropriate to
Classilla, MacWeb or a conservative generic browser profile.

The pre-alpha baseline is a direct proxy: the classic browser connects to an
explicitly enabled listener on the modern host. A guest-local relay through the
NOW wire is a capability-gated second topology. Neither Open Transport nor
MacTCP support for `127.0.0.1`, or even for a connection to the machine's own
configured address, is assumed from modern BSD behavior.

This work graduates the useful TimBotTu browser-bridge implementation and its
68K corpus into NOW ownership. NOW does not import or launch TimBotTu at
runtime.

## Product contract

Three choices remain independent:

- **Browser profile:** Auto, Classilla, MacWeb or Generic 68K. The profile
  chooses the output dialect, page and image budgets, table policy and
  transport pacing.
- **Rendering lens:** Compatible Page, Reader or AI Layout. Compatible Page is
  the deterministic default and the release fallback.
- **Site handlers:** Auto/on/off with individually identified handlers.
  Handlers return the same semantic block tree as the generic engine and
  always fall back to it.

The product never mutates a classic browser's preferences. The guest module
shows the exact address and port to enter, saves the intended browser profile,
and reports whether the selected topology is available.

The first release is read-only navigation: GET and HEAD, no arbitrary CONNECT
tunnel, cookie import, credentials, form replay, uploads or synthetic JS-event
activation. An unsupported interaction remains visible rather than being
silently discarded.

## Authority and provenance

The implementation is graduated from these live sources:

- `../web/proxy/tbtweb/` in the parent TimBotTu repository: the original
  Classilla-verified Chromium bridge, proxy/gateway request handling, SML plan
  adapter, image route and deterministic transcoder.
- `../tbt-web-68k/proxy/tbtweb/`: browser profiles, semantic blocks, HTML 2
  output, pagination and Wikipedia/Reddit handlers.
- `../tbt-web-68k/proxy/bench/`: the 361-URL collection manifest, deterministic
  fixtures and the frozen held-out set.
- `~/Lab/Assets/tbtweb/layout-lfm-v1`: the existing optional layout model.

Copied code receives NOW naming and a provenance note. The corpus is an
engineering and evaluation input, not automatically distributable product
content. Model distribution requires a model card, base-model and dataset
provenance, license review, checksum and explicit optional-component packaging.

## Target contract

| Row | Application model | Networking | UI | Evidence required |
|---|---|---|---|---|
| macOS host | native SwiftUI plus supervised helper | Network.framework / loopback control / selected LAN listener | host Web module | host tests and app builds |
| PPC guest | PowerPC CFM CarbonLib 1.6, Mac OS 8.6-9.2.2 | Open Transport | Workshop module, native Appearance controls | native tests, guest build, mac99, PB1400c |
| 68K guest | classic 68K Toolbox C, System 7.1 | MacTCP | existing NOW-68K single-window surface | native tests, guest build, q800, PB180c |

PPC and 68K listener capability is proved separately. A header declaration,
successful compile or emulator run is not target proof.

## Module map

```text
web-bridge/
  nowweb/                 deterministic Python helper, profiles and adapters
  tests/                  offline fixtures and HTTP integration tests
  config.example.json     explicit install and listener policy
  PROVENANCE.md           graduated source and optional artifact inventory

now-host/Sources/Host/Web/
  WebBridgeProcess.swift  helper lifecycle and bounded log handling
  WebBridgeModels.swift   profiles, lenses, status and configuration
  WebBridgeService.swift  selected-guest policy and request ownership
  WebModuleView.swift     native host module

now-guest-ppc/src/web/
  web_model.*             one state seam for UI, console and wire
  web_http.*              bounded pure HTTP parsing/response helpers
  web_proxy_ot.*          optional Open Transport listener
  web_module.*            Workshop controls, layout and redraw ownership

now-guest-68k/src/web/
  web_model.*             shared contract semantics, 68K-owned implementation
  web_http.*              68K-sized bounded parser
  web_proxy_mactcp.*      capability-gated MacTCP listener
  web_module.*            classic Toolbox UI
```

The exact guest relay wire family is not introduced until the local-listener
probe selects a topology. The direct host proxy does not consume NOW's single
bulk lane and therefore remains usable while Files, Screen or Mirror is active.

## Workstream A - NOW-owned deterministic helper

1. Copy the 68K branch's profile, block, emit, pagination and handler layers.
2. Retain the original proxy/gateway request parser and engine abstraction.
3. Rename the package and remove TimBotTu runtime assumptions.
4. Add a deterministic static engine used by tests and by the host when
   Playwright is unavailable.
5. Add Compatible, Reader and AI-plan lens selection over one semantic block
   tree. Reader is deterministic. The AI adapter may only reorder and group
   existing block IDs; validation failure falls back to Compatible.
6. Preserve HTTP/1.0, explicit Content-Length, no transfer compression and
   profile-bounded output.
7. Add listener-address, allowed-client and outbound-address policy. Public
   HTTP(S) destinations are the default; loopback, link-local and private
   destinations require an explicit unsafe-development switch.

Acceptance: the offline suite covers request forms, link rewriting, profiles,
pagination identity, handler fallback, Reader selection, AI-plan rejection,
address policy and listener peer policy without launching Chromium.

## Workstream B - host ownership and UI

1. Supervise the helper as a separate process with states unavailable,
   stopped, starting, ready, degraded and failed.
2. Validate helper protocol/version before enabling the listener.
3. Keep Chromium and model installation explicit; never download either on a
   browsing request.
4. Add the Web host module with listener state, advertised address/port,
   selected browser profile, default lens, handler policy, engine status and
   optional model identity.
5. Save non-secret configuration in normal host preferences. Never persist
   browser cookies or page content in NOW preferences.
6. Redact URL query/fragment, cookies, authorization and page bodies from
   ordinary host logs.

Acceptance: process lifecycle and configuration tests use a fake helper; the
Swift package suites and Debug/Release app targets build with no helper or
model installed.

## Workstream C - direct classic-browser topology

1. Bind only when the human enables Web, to one selected host interface and
   port.
2. Restrict accepted peers to the selected connected guest address where the
   host can establish it. Make any broader LAN access explicit and visible.
3. Accept gateway-form and HTTP proxy-form requests. Normalize both to one
   bounded request model; do not implement a general CONNECT tunnel.
4. Rewrite every returned link through the gateway so the classic browser
   continues to see plain HTTP while the host fetches HTTPS.
5. Make the host Web module show the exact browser configuration and a local
   test URL.

Acceptance: a scripted classic proxy client exercises a real spawned helper;
Classilla on PB1400c is the required metal row. MacWeb receives its own row and
is never inferred from Classilla.

## Workstream D - guest-local relay probe and contract

Before implementation, run bounded standalone probes for:

- Open Transport listener plus client connections to `127.0.0.1`, the guest's
  configured address and the host address;
- MacTCP passive-open plus the same three destinations;
- actual Classilla and MacWeb request syntax and connection behavior;
- rejection of an unexpected peer and cooperative liveness during menus,
  control tracking, dialogs and window dragging.

If a local topology is supported, add contract messages before either half:

- `web.capabilities`
- `web.request`
- `web.response.begin`
- exact-length bulk response body
- `web.response.end`
- `web.cancel`

Requests are GET/HEAD with a URL, profile, lens and handler policy. The host is
the only pre-alpha service provider, but the messages retain the same meaning
in either direction. Busy bulk-lane admission returns an honest local 503 page
before a fetch begins.

Acceptance: contract fixtures cross real guest encoders and host decoders;
cancel, size limits, unknown profile/lens, unsupported peer and bulk-lane busy
all have typed tests. Contract coverage is re-derived in the same integrated
change.

## Workstream E - PPC Workshop module

1. Add Web as a lazy `WorkshopModuleOps` page with native controls.
2. Display the resolved proxy endpoint; never label an unproved address
   `localhost` or write `127.0.0.1` as a default.
3. Add port, browser profile and default lens preferences through one versioned
   preferences migration.
4. Put listener and response state below one `web_model` seam used by Workshop,
   console commands and wire commands.
5. Resolve Open Transport listener entry points as optional Web capability.
   Missing symbols disable Relay without disturbing NOW's host connection.
6. Keep listener work asynchronous and bounded. Notifier callbacks mutate
   state and invalidate; they never draw. Every nested Toolbox loop continues
   to pump the existing NOW action hook.
7. Accept one browser connection and stream the response; do not allocate a
   document-sized buffer.

Acceptance: native tests cover parser and model state, command parity covers
status/start/stop/profile/lens, guest conformance covers every emitted message,
and the PPC guest builds before emulator or metal claims.

## Workstream F - 68K sibling

1. Re-run the listener probe through MacTCP and preserve Direct as the fallback.
2. Implement a separate non-Carbon module and networking adapter; do not share
   Carbon controls, UPPs or Open Transport state.
3. Keep one connection, 4096-byte or smaller writes, explicit Content-Length,
   no compression and a measured application-heap budget.
4. Reuse contract semantics and conformance fixtures, not native structs.
5. Verify under q800 before PB180c metal. The 384 KB application partition and
   VM-off hardware row remain explicit measurement conditions.

Acceptance: the guest builds and native tests pass; MacWeb Direct browsing is
usable even if MacTCP Relay remains unavailable. Relay is documented only
after target verification.

## Workstream G - site adapters, Reader and optional AI

1. Ship Wikipedia first. Every adapted page includes a Generic View link and
   any handler exception falls back to the generic engine.
2. Retain Reddit's bounded Atom-backed listing behavior and generic fallback;
   do not add credential plumbing without an explicit product decision.
3. Reader emits a reduced projection of the same block tree, preserving source
   and navigation escape links.
4. AI Layout consumes a versioned plan contract over existing block IDs. It
   cannot author links or factual text. Timeout, unavailable model, invalid
   schema and over-budget output all fall back to Compatible Page.
5. Treat `layout-lfm-v1` as externally located until provenance and licensing
   permit optional distribution. Record version and checksum when selected.

Acceptance: held-out evaluation reports content/link preservation, output size,
page count and deterministic fallback separately from subjective layout score.

## Integration sequence

1. Persist this plan and provenance inventory.
2. Land the NOW-owned deterministic helper and offline suite.
3. Add host supervision, Web module and Direct listener.
4. Verify a spawned end-to-end proxy and host Debug/Release builds.
5. Run the PPC/68K local-listener probes and record exact results.
6. If supported, land the contract, host relay and PPC Workshop slice together.
7. Add site adapters and Reader.
8. Add the optional model-plan adapter and packaging metadata.
9. Add the 68K sibling UI/relay path.
10. Run the integrated gate and close current-state documentation.

Each coherent slice receives a checkpoint commit before its long gate. No
contract or guest-served behavior reaches `main` with only one half present.

## Verification and closeout

Integrated verification receipt (merge parent `62c080c4`):

- `scripts/test-all` passed all eight stages after merging current `main`.
  Documentation, release/staged-image discipline, 14 Web Bridge tests, 161
  native tests, MirrorKit, both guest cross-builds and the host
  package/Debug/Release gate passed. The live-guest stage reported its expected
  skip because `NOW_GUEST_LIVE` was not set.
- A private bake and the landing `--shared` bake then cold-booted the integrated
  PowerPC guest. In both runs the guest reported resident 1.2, capability word
  511, source manifest `fae73d4d5c71` and build fingerprint `c725b32b7763`;
  all 14 census probes completed and the guest remained responsive. Finder
  performed both shutdowns, `qemu-img check` passed, and the HFS unmounted bit
  was clean.
- The shared oracle installed by that bake has SHA-256
  `72aeaaf5fc0cacb4bf0cb69abb3439abf99fe31e1a4c51472b603e49e0c15714`;
  `ext/stage-receipts.json` records the exact image and resident inputs.
- Product version `0.2.0`, resident version `1.2`, generated AsyncAPI,
  module/feature manifests and all eight derived documents passed their
  repository gates. This integration does not require another product-version
  increment: it preserves the current pre-alpha product release while adding a
  separately versioned module and preferences migration.
- A separate retained Debug build contained
  `Contents/Resources/WebBridge/nowweb/__main__.py`, and the bundled package's
  CLI entry point launched successfully.
- The bake verified the integrated application and resident lifecycle, not a
  browser request through the Web module. No Classilla, MacWeb, q800 or
  physical-machine Web acceptance row ran. The Web implementation remains
  Tested, not emulator- or metal-verified.

- Helper Python suite and a spawned HTTP integration test.
- Host package suites plus Debug and Release app targets.
- PPC and 68K native tests registered in `scripts/test-native`.
- Both guest cross-builds, with a skip reported as unavailable evidence.
- Documentation and derived-document gates.
- mac99 Web acceptance through the repository harness and a real classic
  browser; the resident-only bake is not a substitute for this row.
- q800 Web acceptance if the 68K configuration surface or relay is added.
- PB1400c/Classilla required before Compatible Page is called metal-verified.
- PB180c/MacWeb required before any 68K Relay or memory-budget claim.

README/status documentation will separate Built, Tested and Metal-verified.
`docs/open-issues.md` will retain local-address behavior, forms/sessions/JS
events, optional model redistribution and any unavailable hardware row as
unverified rather than silently dropping them.
