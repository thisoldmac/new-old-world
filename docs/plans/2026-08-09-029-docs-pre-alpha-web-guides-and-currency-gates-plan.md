# Pre-alpha web guides and documentation currency gates

**Date:** 2026-08-09
**Branch:** `codex/pre-alpha-docs-audit-plan`
**Base:** local `main` at `2598e40e`
**Status:** proposed implementation plan; no guide implementation in this pass

## Outcome

Ship a pre-alpha documentation surface that a person can browse from product
overview to first connection, then learn each module without reading the
engineering history. Give contributors a separate deep developer guide that
traces the host, both guests, the resident, the wire contract, Mirror, agent
integration, builds, verification, and extension workflows. Publish it as
portable Markdown with a web navigation/build layer, many exact-size images or
plainly labeled placeholders, and always-on gates that refuse stale or broken
documentation before it reaches `main`. The published guide lives under the
NOW website's `/docs/` route, inherits the website's global navigation and
footer, and remains buildable as a self-contained artifact for local review.

This is a non-destructive documentation refactor. Existing measurements,
plans, ledgers, investigations, and architecture pages retain their paths and
remain linkable evidence. The new guides curate and route into that corpus;
they do not flatten it into release prose or move it en masse.

## Audit basis

This plan was derived from the documentation surface at `2598e40e`, not from
an assumed greenfield site:

- `docs/` contains 180 tracked files, including 104 top-level Markdown pages,
  but no public docs home, navigation manifest, or site build configuration;
- the README reaches contributor-oriented build/setup material only after a
  long capability and status narrative, and there is no artifact-to-first-
  connection journey for a pre-alpha recipient;
- the host registry declares 14 modules and the PPC Workshop declares 15
  pages, with no machine-checked mapping from those surfaces to user guides;
- existing visual material is historical Mirror evidence rather than a
  systematic host/PPC/68K product tour, while current screenshot prose already
  disagrees with the files present;
- the published Markdown scan found one broken local target among 877 inline
  links, showing generally good hygiene but no gate that keeps it good;
- README descriptions of the test stages and guest modules have drifted from
  executable registries; and
- `tools/derived-doc-gate` protects two valuable coverage documents but is not
  in `scripts/test-all` or CI, remains conditionally armed in hooks, and local
  hook configuration is inconsistent across the active worktree fleet.

The resulting priority is gates and source ownership first, curated journeys
second, and bulk prose/images only after the maintenance boundary exists.

## Working assumptions

1. **Canonical content stays portable.** Author CommonMark/GitHub-flavored
   Markdown, relative links, fenced Mermaid, and ordinary images. Do not make
   the content depend on custom shortcodes that only one site generator can
   understand.
2. **Recommended web adapter: MkDocs Material, pinned.** It gives the current
   tree navigation, search, responsive pages, admonitions, and Mermaid without
   building a bespoke site. The Markdown remains useful on GitHub if the site
   is not deployed. Confirm current versions and official configuration at
   implementation time, then pin the docs environment.
3. **The actual release artifact set is authority.** The guide must name only
   artifacts the pre-alpha really ships. If the release is a zipped `.app`
   plus MacBinary guest files and an optional extension, document that. Do not
   invent a DMG, installer, updater, or notarization story to make the guide
   look complete.
4. **Placeholders may land in pre-alpha.** They must be exact-size, visibly
   labeled, represented in the media manifest, and counted by the release
   check. A placeholder is an honest open slot, never a broken image or an
   unlabeled mock presented as product evidence.
5. **Verification language is a controlled vocabulary.** `Builds`, `Tested`,
   `Emulator-verified`, and `Metal-verified` retain their existing meanings.
   User-facing pages may summarize but must link to the evidence source and
   must not upgrade a verification rung.
6. **The website adapter is not present in this repository.** The first
   implementation slice must identify the NOW website repository, framework,
   deploy workflow, global shell, and canonical production origin before
   wiring publication. MkDocs may produce the static `/docs/` artifact, but it
   must not create a visually or operationally separate second website. If the
   website already has an equally capable documentation pipeline, keep the
   content and gates below and use that adapter instead.

## Standards and publishing contract

The documentation uses a layered standards stack. No site generator is
treated as the content standard.

1. **Information architecture: [Diátaxis](https://diataxis.fr/start-here/).**
   Every curated page declares one primary need: `tutorial`, `how-to`,
   `reference`, or `explanation`. The distinction governs page content, not a
   demand to manufacture four empty directory trees. A reference page links
   to procedures; it does not absorb them.
2. **Authoring: [CommonMark](https://spec.commonmark.org/) plus a narrow GFM
   subset.** Tables, task lists, fenced code, relative links, and ordinary
   images are allowed. Generator-only shortcodes are not canonical content.
3. **Web accessibility: [WCAG 2.2](https://www.w3.org/TR/WCAG22/) Level AA.**
   The site must provide semantic structure, keyboard navigation, visible
   focus, meaningful text alternatives, sufficient contrast, and reflow at
   320 CSS pixels. Automated checks are a floor; the release checklist also
   contains manual keyboard, zoom/reflow, and screen-reader spot checks.
4. **Protocol reference: AsyncAPI.** Human-readable message and command tables
   are generated from `contract/asyncapi.yaml` with a pinned
   [AsyncAPI Generator](https://www.asyncapi.com/docs/tools/generator) toolchain.
   Human pages explain NOW's custom eight-byte binary frame, symmetric service
   rule, limits, and rationale without hand-copying the message inventory.
5. **Web metadata: [Schema.org](https://schema.org/).** Emit
   `SoftwareApplication` on the NOW product page, `TechArticle` on curated
   documentation pages, and `BreadcrumbList` for documentation navigation.
   Generate JSON-LD from validated page metadata instead of duplicating it by
   hand.
6. **Security discovery: [RFC 9116](https://www.rfc-editor.org/rfc/rfc9116.html).**
   Publish `/.well-known/security.txt` over HTTPS from the same maintained
   security-contact source as `SECURITY.md`; do not let two policies diverge.
7. **Ordinary web discovery.** The website owns canonical URLs, redirects,
   `sitemap.xml`, robots policy, social cards, and a no-broken-route check for
   `/docs/`. `llms.txt` may be evaluated later, but is not a source of truth or
   a pre-alpha requirement.

## Information architecture

```text
README.md                         concise repository/product landing
docs/
  index.md                        web documentation home
  user-guide/
    index.md                      what NOW is and where to begin
    tutorials/
      first-connection.md         guided first success from artifacts to session
    how-to/
      choose-a-guest.md            select PPC or 68K from the real compatibility matrix
      install-host.md              install and first launch on modern macOS
      install-ppc.md               copy/install the Carbon guest
      install-68k.md               copy/install NOW-68K
      configure-connection.md      configure both sides and prove the session
      install-extension.md         add the optional resident safely
      recover-a-connection.md      symptom-first connection recovery
      upgrade-rollback-remove.md   replace, roll back, uninstall cleanly
      transfer-a-file.md           representative cross-module task
    explanation/
      two-macs-one-contract.md     product model without implementation detail
      guests-and-compatibility.md PPC vs 68K, honest asymmetries
      verification-and-safety.md  evidence levels and experimental features
      optional-extension.md       why the resident exists and how degradation works
    reference/
      requirements.md             OS, architecture, network, artifact matrix
      limitations.md              concise current pre-alpha limits
      modules/
        screen.md
        files.md
        icloud.md
        processes.md
        mirror.md
        console.md
        chat.md
        hardware.md
        diagnostics.md
        networking.md
        software.md
        mcp.md
        logs.md
        connections-and-preferences.md
  developer-guide/
    index.md
    orientation.md                repo map, ownership, authority order
    architecture/
      system-context.md
      wire-contract.md
      host.md
      ppc-guest.md
      68k-guest.md
      resident-components.md
      mirror.md
      agent-boundary.md
    workflows/
      build-and-test.md
      change-the-contract.md
      add-a-module.md
      emulator-and-metal.md
      documentation-and-gates.md
    reference/
      verification-levels.md
      source-authority.md
      repository-map.md
  assets/
    screenshots/
      manifest.yaml
      overview/
      getting-started/
      modules/<module-id>/
  plans/                         retained snapshots of intent
  research/                      retained research
  *.md                           retained deep references and ledgers
```

The NOW website exposes **Docs** in its global navigation. Within `/docs/`, the
navigation exposes the first-connection tutorial first, task-oriented how-to
guides second, module/reference material third, developer material fourth, and
a deliberately labeled **Engineering records and references** section last.
Plans, dated sweeps, audits, and the append-only ledger stay searchable but do
not appear beside first-run instructions as peers.

## User-guide page contracts

Module pages are Diátaxis reference pages. Every module page uses the same
core sections so readers learn where facts live; the safety, consent, and
privacy section is required only when the criteria in item 6 apply:

1. **What it does** — one paragraph and a hero screenshot.
2. **Availability** — host, PPC, and 68K support plus the exact verification
   rung; intentional absence is stated, not hidden.
3. **On the modern Mac** — controls and normal workflow in the host module.
4. **On the classic Mac** — the PPC Workshop page, then the NOW-68K surface or
   an explicit explanation that it is unavailable.
5. **Common tasks** — outcome-named links to separate how-to pages; no embedded
   multi-step procedure.
6. **Safety, consent, and privacy** — only where the module can mutate state,
   expose personal data, run an agent, or capture content.
7. **Failure states** — messages the person will actually see, with remedies.
8. **Current limitations** — concise, evidence-linked, no copied mutable
   counts.
9. **For developers** — one link into the relevant developer/reference page,
   not an implementation appendix embedded in the user guide.

How-to pages use an outcome-first contract: goal, prerequisites, numbered
steps, expected result, recovery path, related reference, and verification
rung. Tutorials optimize for a safe first success, explain only what the
learner needs at that moment, and end with next tasks. Explanation pages answer
why the system has its shape and carry no imperative setup sequence.

The canonical module manifest maps the 14 host IDs to their guide pages and
the corresponding PPC/68K surfaces. The expected mapping is:

| Guide page | Host ID | PPC Workshop page | NOW-68K posture |
|---|---|---|---|
| Screen | `screen` | Screenshots | supported subset |
| Files | `files` | Files | supported subset |
| iCloud | `icloud` | iCloud | unavailable |
| Processes | `processes` | Processes | supported subset |
| Mirror | `mirror` | Mirror | unavailable |
| Console | `console` | Console | supported |
| Chat | `chat` | Chat | unavailable |
| Hardware | `census` | Hardware | supported subset |
| Diagnostics | `diagnostics` | Diagnostics | declare from live 68K surface |
| Networking | `networking` | Networking | declare from live 68K surface |
| Software | `software` | Software | supported subset |
| MCP | `mcp` | MCP | declare from live 68K surface |
| Logs | `logs` | Logs | declare from live 68K surface |
| Connections and Preferences | `settings` | Preferences + Connection | supported connection UI |

Rows marked "declare from live 68K surface" are not permission to guess.
Implementation must derive the 68K capability/UI map from its current command
and UI registries, then replace those notes with supported, subset, console
only, or unavailable and cite the source.

## Visual system

### Standard capture slots

- **Modern host full module:** 980 × 650 pixels, matching
  `App.swift`'s default content size.
- **PPC Workshop full page:** 744 × 478 pixels, matching the Workshop's
  standard content bounds. If the final capture includes the OS window frame,
  record the resulting outer dimensions in the manifest rather than scaling.
- **NOW-68K full screen:** 640 × 480 pixels for the current target rig; retain
  native dimensions for any 512 × 342 or other real-machine capture and label
  the machine.
- **Workflow detail:** crop from the native capture; do not resample. The
  manifest records the crop rectangle and parent capture.
- **Architecture diagrams:** SVG or Mermaid, with a text explanation directly
  below for accessibility and non-rendering clients.

### Minimum visual coverage

- README/docs home: paired host and Workshop hero images, plus one diagram of
  the two applications and one contract.
- Getting started: artifact layout, host install, PPC install, 68K install,
  host listener setup, guest connection setup, connected state, optional
  extension enabled/disabled, and one troubleshooting example.
- Each module page: one host image and one PPC image. Add a 68K image only when
  the capability has a real UI worth showing; an explicit support card is
  better than a fabricated screenshot.
- Mirror, Files, Screen, Chat, and iCloud: at least one additional task/detail
  image because their normal workflow spans more than one state.
- Developer guide: system context, connection sequence, contract framing,
  file-transfer sequence, Mirror observation/act flow, resident memory
  boundary, MCP trust boundary, and verification ladder.

This creates at least 53 useful visual slots, or 54 when extension enabled and
disabled require separate captures. The first implementation may fill every
slot with a stub, but the pre-alpha release checklist must print the
real-versus-placeholder count and list the remaining IDs.

### Placeholder format

Generate lightweight SVG stubs from `docs/assets/screenshots/manifest.yaml`.
Each stub has the exact declared dimensions and visibly renders:

- `SCREENSHOT NEEDED`;
- module and surface;
- desired state/action in frame;
- required machine/OS;
- privacy notes; and
- expected final dimensions.

Do not hand-author dozens of near-identical SVGs. A deterministic
`tools/docs-placeholders` command writes them from the manifest; a checked-in
test verifies regeneration is clean. Real images replace the placeholder entry
with `status: captured`, add source commit/build stamp, capture date, machine,
and `privacy_reviewed: true`, and may change the file extension to PNG/JPEG.

## Developer-guide diagrams and contracts

The developer guide should contain these diagrams, each adjacent to the source
files that make it true:

1. **System context:** macOS host, PPC guest, 68K guest, optional resident, MCP
   companion, control channel, and bulk channel.
2. **Connection sequence:** listen/dial, `hello`, capability negotiation,
   request/reply, heartbeat, reconnect, and honest refusal.
3. **Ownership map:** contract-first behavior change; host services its side;
   whichever guest receives a symmetric request services its own side.
4. **File transfer sequence:** offer/accept, one bulk lane, progress,
   finalization, fork/metadata preservation, cancellation, and failure cleanup.
5. **Mirror data flow:** perceive/scene, optional content plane, host join,
   semantic render, reference resolution, act, settlement, and authoritative
   reread.
6. **Resident boundary:** shared `peek_table.h`, resident foreign-context
   execution, application foreign-memory reads, optional degradation, leases,
   and no-writer states.
7. **Agent trust boundary:** MCP companion, same-user socket, host catalog,
   guest grant/consent ceiling, audit record, and typed refusal.
8. **Verification ladder:** build, native/unit test, host integration, emulator,
   metal, and which claims each rung may make.

The contract reference itself should be generated or projected from
`contract/asyncapi.yaml`; do not rewrite a second hand-maintained list of
messages and `x-commands`. Human pages explain semantics and link to generated
tables.

## Documentation metadata

New curated pages receive a small, validated front matter block:

```yaml
page_id: files-reference
doc_type: reference # tutorial | how-to | reference | explanation
audience: user | developer | operator
lifecycle: current | experimental | reference | historical
authority:
  - path/to/source-or-canonical-doc
module_ids: [files]
source_dependencies:
  - now-host/Sources/Host/ModuleRegistry.swift
media_ids:
  - files-host-overview
last_verified: 2026-08-09
```

The same record supplies the page title, description, canonical URL,
breadcrumb, `dateModified`, and Schema.org `TechArticle` JSON-LD. Curated pages
must have exactly one primary `doc_type`; related needs are links, not a second
page shape hidden inside the first.

Avoid authors/owners that become stale when people change. Ownership is by
source boundary: user guide, host module, PPC module, 68K module, contract, or
release packaging. Legacy documents do not all need front matter in the first
pass; `docs/reference-index.yaml` classifies them for navigation and search
without creating a 180-file churn commit.

## Gates

### 1. `scripts/test-docs` — fast, always-on

Run before native/build gates and in its own CI job. It must:

1. build the pinned MkDocs site with warnings treated as errors;
2. reject broken local links, missing fragments, missing images, and duplicate
   conflicting page IDs;
3. require non-empty alt text and manifest entries for guide images;
4. validate actual image dimensions against the manifest;
5. regenerate placeholder SVGs into a temporary directory and compare them to
   the checked-in files;
6. require every curated page in navigation and reject navigable orphans;
7. validate front matter and controlled vocabularies;
8. derive host/PPC/68K module registries and require complete, explicit guide
   coverage including intentional asymmetries;
9. run all guide `derived-doc`/source-digest checks in strict mode;
10. validate Mermaid during the site build or with a pinned renderer;
11. generate the AsyncAPI reference into a temporary directory and require it
    to match the checked-in or published artifact;
12. validate generated canonical URLs, breadcrumbs, and Schema.org JSON-LD;
13. run automated accessibility checks on representative rendered pages,
    including the home, tutorial, how-to, module reference, developer page,
    tables, diagrams, and image placeholders;
14. validate the website integration contract: `/docs/` base path, asset URLs,
    global navigation link, sitemap membership, redirect map, and
    `/.well-known/security.txt`; and
15. print a concise summary: pages by Diátaxis type, links, real images,
    placeholders, module
    coverage, stale derivations.

The gate must remain host-only and cheap. It boots no emulator and reaches no
Macintosh.

Automated accessibility output must not say the site is "WCAG certified."
The pre-alpha release checklist records the manual keyboard, 200%/400% zoom,
320 CSS-pixel reflow, and screen-reader spot checks separately.

### 2. Source-backed currency declarations

Reuse `tools/derived-doc-gate` semantics rather than creating a parallel hash
format. Extend it only as needed to support guide manifests and strict PR
checks. Initial source groups:

- module pages: host `ModuleRegistry.swift`, PPC Workshop enum/registry/sidebar,
  and the 68K UI/command registries;
- contract guide: `contract/asyncapi.yaml` and shared frame/limit headers;
- build/test guide: `scripts/test-all`, `scripts/test-host`,
  `scripts/test-native`, `scripts/build-guests`, and CI;
- compatibility/setup guide: product identity, guest build targets, deployment
  artifact naming, minimum OS/CarbonLib declarations, and release manifest;
- resident guide: `contract/peek_table.h`, `ext/` lifecycle entrypoints, and
  `docs/resident-components.md`;
- MCP guide: projection/tool catalog, companion transport, consent/grant
  sources, and `docs/mcp-coverage.md`.

A source change that leaves a derived answer unchanged still requires an
explicit re-derivation record. This catches renamed arguments and changed
semantics that counts cannot see.

### 3. Main-landing enforcement

Wire the same check in three places:

- `scripts/test-all` as the first, cheapest stage;
- `.github/workflows/ci.yml` as a dedicated required docs job; and
- both Git merge paths (`pre-merge-commit` and conflicted-merge `pre-commit`).

When a Git remote is configured, make the docs job a required status check in
the `main` branch ruleset and refuse direct unverified pushes. A workflow file
that exists but is not required is evidence of a runnable check, not a landing
gate. Record the required-check name in the repository so a workflow rename
cannot silently detach branch protection.

Do not rely on hooks as the only authority: this clone already has many
worktree-specific hook paths. CI and `scripts/test-all` make the check visible
and reproducible even when local hook configuration is wrong.

Before removing the existing `NOW_DERIVED_DOC_GATE` arming condition or adding
an unconditional docs gate to shared hooks:

1. run `tools/gate-impact-sweep` across active branch namespaces;
2. classify any stranded branch and repair the gate or document the migration;
3. run `tools/hooks-doctor` and report shadowed/missing hook paths;
4. land the gate implementation and mutation tests before the hook arming
   commit; and
5. arm only when no in-flight branch is unexpectedly blocked.

### 4. Mutation evidence

The documentation gate is incomplete until these mutations have been watched
fail for the claimed reason, then restored to green:

- add a host module with no guide mapping;
- add a PPC Workshop page with no declared host asymmetry;
- change an existing contract command argument so counts remain unchanged;
- delete a real image and leave its Markdown/manifest entry;
- remove alt text;
- change an image's dimensions;
- leave a placeholder file out of date with its manifest;
- break a local link and a heading fragment;
- remove a page from navigation;
- break Mermaid syntax;
- mix a multi-step procedure into a module reference page fixture;
- omit `doc_type` or emit two primary types;
- make generated AsyncAPI output stale while the contract still parses;
- remove a breadcrumb/canonical URL or emit invalid JSON-LD;
- introduce a keyboard-inaccessible navigation control or an unlabeled image
  fixture caught by the automated accessibility runner;
- break `/docs/` asset paths under the production base URL;
- let `security.txt` disagree with its maintained security-contact source;
- merge two branches that each honestly re-derived different source states;
- prove the docs job actually runs in CI/test-all rather than merely existing.

## Implementation sequence

### Slice 1 — Establish the docs contract and gate skeleton

- Locate the NOW website source/deploy owner and record its framework,
  production origin, `/docs/` mount contract, global shell, and preview path.
- Add the pinned docs environment, `mkdocs.yml`, `scripts/docs-serve`,
  `scripts/docs-build`, and `scripts/test-docs`.
- Add Diátaxis page-type, metadata, navigation, module-manifest, and
  media-manifest schemas.
- Implement link/fragment, nav/orphan, image/alt/dimension, and placeholder
  validation.
- Add the AsyncAPI generation target, structured-data generation, base-URL
  checks, and representative automated accessibility fixtures.
- Add mutation tests before writing the bulk pages so the new corpus grows
  inside its maintenance boundary.

**Gate:** a minimal tutorial, how-to, reference, and explanation site builds
inside a production-shaped `/docs/` preview; each validator has a watched
failure; the gate is not yet armed fleet-wide.

### Slice 2 — Create the navigation and concise entrypoints

- Add `docs/index.md`, user/developer guide indexes, and the reference index.
- Rewrite the README as a concise product/repository landing: hero, what NOW
  does, compatibility, honest pre-alpha status, quick links, and contributor
  path.
- Correct the current test-stage, module-layout, and screenshot inventory
  drift while removing copied details the new guides own.
- Keep old document paths intact and classify them in navigation.
- Wire canonical URLs, breadcrumbs, structured metadata, sitemap entries, and
  the website's global Docs navigation in the preview environment.

**Gate:** a reader can reach first setup, modules, limitations, developer
orientation, security, and deep references from the landing page without
opening the issue ledger first.

### Slice 3 — Write and verify the complete getting-started journey

- Freeze the pre-alpha artifact manifest from the actual packaging output.
- Write one guided first-connection tutorial; separate how-to pages for guest
  choice, host/PPC/68K installation, connection configuration, extension
  installation, file transfer, recovery, and upgrade/rollback/remove; and
  concise reference and explanation pages for requirements, compatibility,
  the two-Mac contract model, verification and safety, current limitations,
  and the optional resident.
- Test every command/path against a clean staging location and the exact build
  artifacts. Record what was only built, emulator-tested, or metal-verified.
- Add setup visual slots and placeholder stubs.

**Gate:** an unfamiliar reader can identify the right guest and reach a
verified connection without needing `.env.lab`, the contributor build path,
or private lab values.

### Slice 4 — Build the 14-page module guide

- Implement the module manifest extractor first.
- Use one template and write pages in small groups: Screen/Files/iCloud;
  Processes/Mirror/Console; Chat/Hardware/Diagnostics; Networking/Software;
  MCP/Logs/Connections and Preferences.
- Derive availability from the current contract/coverage sources and verify
  actual UI labels from source or screenshots.
- Add paired host/PPC visual slots and honest 68K treatment.
- Keep procedures in task pages and make each module page a bounded reference
  that links to them.

**Gate:** all live module IDs are mapped exactly once; every page has the
required sections, source dependencies, media IDs, and current limitations.

### Slice 5 — Build the developer deep dive

- Write orientation and source authority first.
- Add the eight architecture/sequence diagrams and their text equivalents.
- Split user-relevant explanation from implementation detail while linking to
  existing deep pages for measurements and historical reasoning.
- Write the three change recipes that protect the project's real seams:
  contract change, module addition, and emulator/metal verification.
- Document the documentation gate itself so the next contributor knows how to
  rederive rather than bypass it.

**Gate:** a contributor can trace one module from host UI through the contract
to both guest dispatchers and tests, and can explain which side owns each
behavior and verification claim.

### Slice 6 — Replace priority placeholders and review the site

- Capture the README hero pair, first-connection flow, and the five highest
  value modules first: Files, Screen, Mirror, Chat, and iCloud.
- Capture at native dimensions, preserve classic pixels, and complete privacy
  review before changing manifest status to `captured`.
- Keep remaining stubs visible and counted; do not block pre-alpha solely on
  lower-priority placeholder slots unless the release profile says otherwise.
- Review desktop and narrow web layouts, keyboard navigation, alt text,
  contrast, diagram readability, and page load size.
- Complete the manual WCAG release checklist at keyboard-only, 200% and 400%
  zoom, 320 CSS-pixel reflow, and with a screen-reader spot check across each
  representative page type.

**Gate:** no broken or unlabeled image slots; the release report lists every
remaining placeholder by ID and page.

### Slice 7 — Wire, impact-test, and arm landing enforcement

- Add docs as stage 1 of `scripts/test-all` and renumber its documentation.
- Add the dedicated CI docs job.
- Make that exact job name required by the remote `main` ruleset and verify a
  deliberately failing docs PR cannot merge. If the remote is still absent,
  record this as a release blocker rather than treating local hooks as an
  equivalent control.
- Wire the docs artifact into the NOW website preview and production build,
  including canonical URLs, sitemap, redirect checks, and `security.txt`.
- Extend derived/source checks to all curated source groups.
- Run the gate impact sweep and mutation suite.
- Arm both merge paths only after the fleet check is safe.
- Update AGENTS/CONTRIBUTING with the one command and the rederive workflow.

**Gate:** a stale module guide, contract guide, setup claim, broken link,
missing image, or invalid site build is refused before `main`; the refusal
names the exact page, source, and repair command.

### Slice 8 — Pre-alpha reconciliation and release closeout

- Run `scripts/test-docs` and `scripts/test-all` at the final tree.
- Re-derive after the final integration merge, not only on feature branches.
- Review the user guide against the packaged artifacts one last time.
- Review limitations against `docs/status.md`, `docs/known-wrong.md`,
  `docs/open-issues.md`, contract coverage, and MCP coverage without copying
  volatile counts.
- Close the old screenshot gap only for real captures, not placeholders.
- Record build/test/emulator/metal status precisely and produce the final
  placeholder and broken-link counts in the release notes.

**Gate:** clean docs/site build, zero broken local links/fragments, complete
module mapping, current source digests, explicit placeholder inventory, and no
claim above its verification evidence.

## Reviewable commit shape

1. `docs: add web guide scaffold and documentation checks`
2. `docs: add pre-alpha overview and getting started guide`
3. `docs: add Screen, Files, and iCloud module guides`
4. `docs: add Processes, Mirror, Console, and Chat guides`
5. `docs: add Hardware, Diagnostics, Networking, and Software guides`
6. `docs: add MCP, Logs, Connections, and Preferences guides`
7. `docs: add developer architecture and contract guide`
8. `docs: add visual manifest and priority captures`
9. `test: enforce documentation currency in local and CI gates`
10. `docs: reconcile pre-alpha limitations and release navigation`

Adjust grouping if a commit grows hard to review; do not collapse the whole
guide into one catch-all change.

## Acceptance criteria

- The README is a concise landing page, not the long-form status ledger.
- The docs home clearly separates users, developers, and engineering records.
- Curated content follows Diátaxis: every page has one primary type, module
  pages are reference, and multi-step procedures live in how-to/tutorial pages.
- A user can identify compatibility, install both halves, make a first
  connection, understand the optional extension, and find rollback/remove
  instructions.
- Every host module and every PPC Workshop page is mapped to exactly one guide
  page or an explicit paired asymmetry; NOW-68K support is explicit.
- Every module page follows the shared core section contract, includes the
  safety, consent, and privacy section when item 6's criteria apply, and has at
  least two visual slots.
- Visual slots are real captures or exact-size labeled placeholders; all have
  alt text, manifest entries, dimensions, and privacy status.
- The developer guide contains the eight named diagrams and traces contract,
  host, PPC, 68K, resident, Mirror, MCP, and verification ownership.
- Existing deep documentation remains reachable at its old path.
- `scripts/test-docs` runs first locally and in CI, and the site builds with
  warnings as errors.
- The same artifact renders under the NOW website's `/docs/` route with its
  global navigation/footer, canonical production URLs, sitemap entries,
  breadcrumbs, valid Schema.org JSON-LD, and a maintained RFC 9116
  `security.txt`.
- Representative pages pass automated accessibility checks, and the pre-alpha
  release records manual WCAG 2.2 AA keyboard, zoom/reflow, and screen-reader
  review without claiming automated certification.
- Protocol reference output is generated from `contract/asyncapi.yaml` and a
  contract edit cannot leave published reference tables stale.
- Link, fragment, navigation, metadata, module, image, placeholder, diagram,
  and source-currency failure classes have mutation evidence.
- Merge-time re-derivation catches sibling-branch drift even when derived
  counts are unchanged.
- Final release reporting states verification level and remaining placeholder
  count without calling unrun behavior working.

## Explicit non-goals

- Rewriting or deleting the append-only issue ledger.
- Moving every existing document into a new directory before pre-alpha.
- Generating release claims directly from plans or dated handoffs.
- Building a custom documentation web application.
- Treating placeholders as verification evidence.
- Documenting packaging, auto-update, notarization, or installers that do not
  exist.
- Making hardware/emulator availability a prerequisite for the host-only docs
  gate.
