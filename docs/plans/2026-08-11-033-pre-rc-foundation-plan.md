---
title: Pre-RC repository and module foundations plan
type: plan
date: 2026-08-11
status: approved
search:
  exclude: true
---

<!-- now-doc-provenance: generated reviewed=false -->

# Pre-RC repository and module foundations

## Objective

Establish the repository-wide conventions, documentation provenance, feature
policy, and atomic module ownership needed before New Old World cuts its next
release candidate. This plan prepares `main` for RC1 feature work; it neither
defines the rest of RC1 nor cuts, packages, tags, or publishes a candidate.

The private `thisoldmac` GitHub repository is the integration authority for
this work. The private-history and reconditioning lines remain preserved as
provenance and must not acquire the GitHub remote or become the integration
checkout.

## Outcomes

When this slice is complete:

- new branches and commits use creator-neutral Conventional Git naming;
- every committed Markdown file has explicit authorship and review provenance;
- one product-feature authority drives documentation and runtime defaults;
- `core | experimental | debug` is module taxonomy, not runtime behavior;
- runtime feature flags remain distinct from release inclusion and guest
  capabilities;
- host and PowerPC modules are statically linked but independently own their
  metadata, construction, view or page, lifecycle, and cleanup;
- NOW-68K remains a separate non-Workshop sibling; and
- foundation and ongoing feature work can continue merging to `main` without
  implying that an RC exists.

## Authority model

These dimensions answer different questions and must not be collapsed:

| Dimension | Question | Initial values |
|---|---|---|
| Module taxonomy | What kind of product surface is this? | `core`, `experimental`, `debug` |
| Future domains | What areas of the product does it belong to? | additive, independently owned taxonomy |
| Release profile | Does this release include it? | `included`, `optional`, `excluded` |
| Runtime flag | Is the compiled feature admitted now? | enabled, disabled, or explicitly overridden |
| Guest capability | Can this connected machine serve it? | supported, unsupported, or unknown |
| Document lifecycle | How should this page be treated? | `current`, `reference`, `historical` |

Availability resolves centrally:

```text
compiled in
+ admitted by release profile
+ enabled by runtime policy
+ supported by the connected guest
= available
```

Capability negotiation must not be duplicated by feature booleans. Taxonomy
must not silently set a release state, runtime default, or navigation rule.

## Integration discipline

Before the atomicity refactor begins, inventory active branches touching:

- `now-host/Sources/Host/ModuleRegistry.swift`;
- `now-host/Sources/Host/HostRootView.swift`;
- `now-host/Sources/Host/HostAppState.swift`;
- `now-guest-ppc/src/workshop/workshop_module.h`;
- `now-guest-ppc/src/workshop/workshop_window.c`; or
- `now-guest-ppc/src/workshop/workshop_sidebar.c`.

Land ready feature work first or explicitly rebase it onto the new foundation.
During the central seam change, freeze only those composition files, not
general product development. Each pull request below lands independently on a
green `main`; no catch-all integration branch holds the whole program hostage.

Existing active branches are grandfathered through the Git transition and are
not renamed merely for conformance.

## Workstream 1: Conventional Git transition

### Branch

The transition itself uses the final current-policy name:

```text
dev/tooling/conventional-git
```

After it merges, new work uses:

```text
feat/<kebab-slug>
fix/<kebab-slug>
docs/<kebab-slug>
refactor/<kebab-slug>
test/<kebab-slug>
build/<kebab-slug>
ci/<kebab-slug>
chore/<kebab-slug>
perf/<kebab-slug>
revert/<kebab-slug>
```

Release qualification retains `release/vX.Y.Z`. Explicitly permitted
service-managed namespaces such as Dependabot remain service exceptions, not
precedent for human or agent ownership prefixes.

### Changes

- Remove `codex/`, `claude/`, `thread/`, `fork/`, and other creator prefixes
  from current contributor guidance.
- Replace `dev/<domain>/<slug>` with `<type>/<kebab-slug>`.
- Keep technical domain in pull-request metadata or an optional Conventional
  Commit scope rather than encoding worker identity in the branch.
- Adopt `type(scope): summary`, with scope optional, for new commit and squash
  titles.
- Update `AGENTS.md`, `CONTRIBUTING.md`, `RELEASING.md`, the pull-request
  template, hook output, examples, and CI.
- Add one branch and title validator with a mutation-tested fixture suite.
- Grandfather branches whose merge base predates the policy commit. A branch
  rebased across the transition adopts the new name rather than carrying the
  exception indefinitely.

### Acceptance

- A new creator-prefixed branch fails by name.
- A pre-transition active branch can still land.
- Representative feature, fix, docs, refactor, service, and release names pass.
- An invalid type, extra ownership prefix, empty slug, or non-kebab slug fails.
- `main` remains pull-request-only integration and does not become a release
  merely because it is green.

## Workstream 2: Documentation provenance

### Branch and archive point

```text
docs/provenance-tags
```

Immediately before this work changes the corpus, create an annotated,
non-release tag on the exact current `main`:

```text
archive/docs-pre-rewrite-YYYY-MM-DD
```

Do not create a GitHub release from this tag. Recount the tracked Markdown
corpus at implementation time rather than freezing the earlier 250-file count.

### Marker

Use one universal HTML comment that works in Markdown with or without YAML
front matter:

```markdown
<!-- now-doc-provenance: generated reviewed=false -->
```

After a human rewrite, remove the generated marker rather than replacing it
with another authorship category:

```markdown
<!-- now-doc-provenance: reviewed=false -->
```

After review:

```markdown
<!-- now-doc-provenance: reviewed=true -->
```

`generated` is a presence marker; `generated=false` is invalid. `reviewed` is
explicit and independent of authorship. Do not add `retained-source` or another
authorship category.

### Changes

- Mark the existing committed Markdown corpus as generated.
- Extend the documentation gate to require exactly one valid provenance marker
  on every tracked Markdown file.
- Render appropriate provenance on published pages while leaving repository
  and scratch material unrendered.
- Require generated projections and derived documents to retain `generated`.
- Document the rewrite and review workflow for contributors.
- Add mutation cases for missing, duplicated, malformed, contradictory, and
  improperly removed markers.

This work installs provenance infrastructure. It does not perform the planned
human rewrite.

## Workstream 3: Feature-policy foundation

### Branch

```text
feat/feature-flags
```

### Authority

Promote the current documentation-owned feature catalog into a product-owned
authority, recommended as:

```text
product/features.yaml
```

The documentation site, Swift host, PowerPC guest, packaging checks, and tests
derive from this file. Moving the authority satisfies the existing rule that
runtime flags must consume the documentation keys or replace the catalog as
the single authority; it must not leave a second hand-maintained availability
matrix under `docs/`.

### Changes

- Preserve stable feature IDs, including the reserved `classic.pre-carbon`.
- Generate bounded Swift and C definitions from the product authority.
- Gate generated definitions and rendered documentation for freshness.
- Add injectable host and PPC policy resolvers with reason-bearing outcomes.
- Preserve current runtime behavior by default.
- Use `classic.pre-carbon` as the first real present-but-off catalog binding.
- Keep capability negotiation separate from runtime admission.
- Do not add a general feature-flag editor. A flag becomes user-configurable
  only when its product design names who may change it, where, and with what
  persistence and recovery behavior.

### Presentation

- Profile-excluded features are absent from shipped navigation and named in
  release documentation.
- Runtime-disabled compiled features present an honest disabled reason when a
  user can encounter them.
- Capability-unavailable modules distinguish unsupported, disconnected, and
  unknown states.

## Workstream 4: Atomic module foundation and taxonomy

### Branch

```text
refactor/module-atomicity
```

Taxonomy is implemented as part of this module foundation, not as a parallel
feature-flag system.

### Taxonomy

Extend the module authority with independently named fields:

```yaml
id: networking
tier: core
domains: []
feature_flag: null
```

Initial proposed tiers, using stable product module IDs:

- Core: `screen`, `files`, `processes`, `console`, `census`, `networking`,
  `software`, `settings`.
- Experimental: `icloud`, `mirror`, `chat`, `web`, `development`, `mcp`.
- Debug: `diagnostics`, `logs`.

`domains` remains independently extensible for later product organization.
Do not invent compound tier values such as `experimental-debug-networking`.
Core needs no noisy badge; experimental and debug modules receive consistent
labels in module documentation and their module UI. Tier changes explanation
and presentation only.

### Host seam

Introduce a statically linked host module definition that owns:

- stable module ID and descriptor;
- taxonomy and optional feature key;
- model construction;
- view construction;
- guest-focus hooks where applicable; and
- shutdown and cleanup.

The registry composes definitions. `HostRootView` renders the selected
definition instead of switching over every module ID. Module-specific models
move out of `HostAppState` as their modules migrate, while the listener,
logging, settings, and other actual application services remain at the
composition root. Saved stable IDs and rename forwarding remain compatible.

### PowerPC seam

Add a static `WorkshopModuleDefinition` around the existing
`WorkshopModuleOps` with:

- stable product module ID;
- existing numeric Workshop page ID;
- title, placement, taxonomy, and optional feature key; and
- ops pointer and lifecycle state.

Replace the parallel metadata and ops arrays with a registry of definitions.
Preserve existing numeric IDs and preferences, separate display order from
numeric identity, and retain transactional construction and rollback. The
central static catalog may be generated or validated, but dynamic plug-ins and
toolchain-specific linker registration add no pre-alpha value.

One product module may map to multiple PPC pages. In particular, `settings`
continues to own both Preferences and Connection. The host and PPC definitions
remain separate native implementations joined only by stable product IDs and
catalog metadata.

NOW-68K remains outside this interface. Its command and main-window surfaces
continue to map into the product documentation without acquiring a Workshop.

### Representative migration

Use `networking` as the default pilot: it exists on host and PPC, has bounded
state, and does not depend on the resident extension.

The pilot proves:

- registration without central metadata duplication;
- enabled and policy-disabled resolution;
- lazy construction;
- failed-construction rollback;
- selection and saved-selection fallback;
- guest-focus changes;
- cleanup on close or shutdown;
- taxonomy and documentation rendering; and
- host, PPC, and manifest ID parity.

## Workstream 5: Bounded module migrations

After the seam and pilot land, migrate remaining product modules on branches
named for the module:

```text
refactor/module-atomicity-console
refactor/module-atomicity-hardware
refactor/module-atomicity-software
refactor/module-atomicity-screen
refactor/module-atomicity-files
refactor/module-atomicity-processes
refactor/module-atomicity-icloud
refactor/module-atomicity-chat
refactor/module-atomicity-web
refactor/module-atomicity-development
refactor/module-atomicity-mirror
refactor/module-atomicity-mcp
refactor/module-atomicity-diagnostics
refactor/module-atomicity-logs
refactor/module-atomicity-settings
```

Each branch migrates host and PPC ownership for one product module where both
surfaces exist. `settings` deliberately migrates its two PPC pages together.
Complex modules such as Mirror and MCP land after simpler modules have proved
the seam.

Suggested order:

1. networking pilot;
2. console, census/Hardware, and Software;
3. Screen, Files, and Processes;
4. iCloud, Chat, Web, and Development;
5. Mirror and MCP; and
6. Diagnostics, Logs, and Settings.

## Gates and verification

Add or extend gates for:

- branch and Conventional Commit syntax;
- documentation provenance completeness and rendering;
- feature-schema and generated Swift/C freshness;
- unique stable feature and module IDs;
- valid taxonomy values;
- manifest, host, and PPC parity;
- absence of a module-specific `HostRootView` switch after migration;
- absence of orphaned `HostAppState` module ownership after migration;
- PPC ordering and saved-preference compatibility;
- disabled, unsupported, and unknown availability states; and
- construction rollback and cleanup.

Every new guard is watched failing against the exact mutation it claims to
catch. Each pull request runs its focused gates and `scripts/test-all`, naming
every skip. The pilot receives an emulator navigation, construction, and
cleanup sweep. A complete physical-hardware module sweep remains an RC1
qualification item rather than blocking every migration pull request.

## Explicit exclusions

This foundation slice does not include:

- cutting or publishing an RC;
- RC packaging automation;
- dynamic plug-in loading;
- turning NOW-68K into a Workshop application;
- automatically disabling modules because they are experimental or debug;
- rewriting the documentation corpus;
- renaming active legacy branches;
- folding guest capability negotiation into feature flags; or
- unrelated module feature work.

## Completion condition

The slice is complete when all migrations are on green `main`, current product
behavior is preserved except for explicitly approved flag defaults, and new
RC1 features can be added as self-contained modules without editing central
host or Workshop dispatch switches. The next RC remains a later qualification
decision made from the complete RC1 feature set.
