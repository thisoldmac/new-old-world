# Mirror pre-merge consolidation

**Status:** Proposed. This plan prepares `codex/mirror-session-teardown` for
landing; it does not authorize the implementation units by itself.

**Planning baseline:** `codex/mirror-session-teardown` at `d979c6ee`, clean on
2026-08-09. Current `main` is `7d906f15`; the branch is 1,365 commits ahead and
23 commits behind. A synthetic merge reports three content conflicts:
`README.md`, `docs/open-issues.md`, and `scripts/build-host-app`.

## Outcome

Land the Mirror integration as part of New Old World without leaving the
copied standalone Mirror product in the active tree. The landed revision must:

- keep the production `MirrorKit` and `MirrorKitUI` modules under NOW
  ownership;
- archive the complete standalone Mirror project, its standalone host app,
  guest, resident components, tests, tools, assets, and build experiments;
- retain the detailed Finder, GWorld, A5-world, and cursor research in live NOW
  documentation and the parent TimBotTu findings corpus;
- state the experimental and unverified Mirror behavior honestly;
- pass the repository gates from the exact revision that is landed;
- produce and verify the new shared PPC emulator image only after the tree is
  frozen; and
- leave remote cursor driving as the first bounded follow-on from the landed
  `main`.

## Authority and settled decisions

1. NOW is the product. The imported standalone Mirror is historical source and
   research provenance, not a second maintained product.
2. Finder P3 remains permanently disabled. Finder interiors are semantic and
   host-rendered; the current fully emulated Finder mode remains explicitly
   experimental.
3. P3 remains available only for identified non-Finder applications and is
   off by default. Emulator rendering evidence is not metal-safety evidence.
4. The host always launches with Mirror off.
5. Asset packs are private, regenerable runtime dependencies. No extracted
   Apple asset pack ships from the repository or is hard-coded to one pack
   instance.
6. Detailed research is promoted before archival. An archive may retain raw
   evidence, but it may not become the only discoverable copy of a conclusion.
7. Preserve the branch history. Merge current `main` into the branch; do not
   squash or rebase this integration history immediately before landing.
8. Bake the shared VM only from the final green revision. A bake from an
   intermediate tree is not the release image.

## Scope boundaries

### In scope

- Merge reconciliation with current `main`.
- Extraction of production-owned Mirror Swift modules and asset parsers.
- Archival of the complete standalone Mirror tree.
- Graduation of tracked research currently under `docs/local/`.
- NOW documentation and parent corpus updates.
- Source, build, host, guest, emulator, and narrowly scoped metal gates.
- Shared PPC image bake and receipt.
- A final host artifact and main-landing procedure.

### Out of scope

- Making experimental Finder emulation production-ready.
- Implementing general remote cursor driving.
- Expanding P3 to Finder or weakening its identity boundary.
- Blacklisting individual applications such as Sherlock.
- Reorganizing the whole `docs/open-issues.md` ledger.
- Rewriting Git history to remove old asset objects.
- Deleting or pruning foreign worktrees, private VM clones, or prior archives.

## Current extraction boundary

The active tree cannot simply move `mirror/` to `archive/` today:

- `now-host/Package.swift` and the Xcode project depend on
  `mirror/host/MirrorKit`.
- Host and package tests inspect source files under that path.
- `scripts/test-mirrorkit` builds the package there, including the standalone
  `MirrorApp` executable.
- `tools/extract-assets-offline` imports parsers from
  `mirror/tools/extract-assets` and writes generated output beneath the
  MirrorKit source tree by default.
- The tracked `mirror/assets/platinum-pack` is an imported private asset copy,
  not the runtime-selected pack. Runtime selection already uses the external
  `~/Lab/Assets/now-mirror-assets/pack-*/Resources` store or
  `NOW_MIRROR_ASSETS`.

The production extraction is therefore deliberately narrower than the
standalone project:

| Source | Active destination | Disposition |
|---|---|---|
| `mirror/host/MirrorKit/Sources/MirrorKit` | `now-host/Packages/MirrorKit/Sources/MirrorKit` | Extract unchanged module ownership, then evolve under NOW |
| `mirror/host/MirrorKit/Sources/MirrorKitUI` | `now-host/Packages/MirrorKit/Sources/MirrorKitUI` | Extract unchanged module ownership, then evolve under NOW |
| Production-relevant core/UI tests | `now-host/Packages/MirrorKit/Tests/` | Retain and keep gated |
| `MirrorOracleKit` | archive | QMP/legacy standalone adapter; the production host deliberately excludes it |
| `MirrorApp` | archive | Standalone host executable being retired |
| `mirror/tools/extract-assets` | `tools/asset-pack/` | Retain parsers used by NOW's offline extractor |
| `mirror/assets/platinum-pack` | archive | Preserve imported bytes as history; never resolve it as a shipping pack |
| `mirror/guest`, `mirror/tests`, remaining `mirror/tools`, `mirror/docs` | archive | Raw standalone implementation and research provenance |

Copy the production targets out before moving the source tree so the archive
remains a complete final snapshot rather than a carcass with its useful parts
removed.

## Execution units

### U0. Freeze the baseline and merge current main

**Goal:** Begin structural work from one recoverable, current revision.

**Actions**

- Recheck branch, dirt, worktrees, running QEMU processes, metal machine/port
  ownership, and the parent findings worktree.
- Create a non-moving safety ref naming `d979c6ee` before reconciliation.
- Merge `main` into `codex/mirror-session-teardown`; do not rebase.
- Resolve the three predicted conflicts by meaning:
  - `README.md`: retain both current main capabilities and the honest Mirror
    works/does-not-work account.
  - `docs/open-issues.md`: retain both ledgers without wholesale
    reformatting.
  - `scripts/build-host-app`: retain current main packaging/signing changes and
    Mirror's current SwiftPM/Xcode build inputs.
- Inspect every auto-merged host source and test touched by both sides. A clean
  textual auto-merge is not proof that two state models compose.
- Run `scripts/test-host` and the cheapest native tests before starting path
  moves. Commit the reconciled baseline separately.

**Stop conditions**

- Stop if the worktree is dirty before the merge for reasons not belonging to
  this branch.
- Stop if `main` advances again before the structural work begins; merge the
  new head first.
- Stop if reconciliation changes a wire behavior without a matching contract
  and both-side review.

### U1. Extract NOW's production Mirror package

**Goal:** Make NOW self-contained without carrying the standalone executable
or QMP oracle in its active dependency graph.

**Actions**

- Create `now-host/Packages/MirrorKit` containing the `MirrorKit` and
  `MirrorKitUI` library products.
- Preserve the public module names so host imports and API contracts do not
  churn during the move.
- Copy core/UI tests. For each test importing `MirrorOracleKit`, either:
  - retarget it to the production library if it tests shared behavior; or
  - leave it with the archive if it tests QMP or standalone-app behavior.
- Update `now-host/Package.swift`, the Xcode local package reference,
  `scripts/test-mirrorkit`, `scripts/test-all`, path-sensitive host tests,
  `docs/arc-triggers.conf`, and non-historical source comments.
- Keep the production boundary test that proves NOW Host does not link
  `MirrorOracleKit` or QMP.
- Change `scripts/test-mirrorkit` to build and test the two libraries; it must
  no longer build `MirrorApp`.

**Verification**

- `swift package describe` resolves only the NOW-owned local package.
- Focused MirrorKit and MirrorKitUI suites pass both with the selected asset
  pack and with `NOW_MIRROR_ASSETS=none`.
- Host tests prove no production target links `MirrorOracleKit`, `MirrorApp`,
  or QMP.
- Debug and Release Xcode app targets build.

**Commit boundary:** production package extraction only.

### U2. Extract the asset toolchain and close the private-pack seam

**Goal:** Preserve regenerability without keeping active tooling or generated
Apple assets under the standalone tree.

**Actions**

- Move the reusable parsers to `tools/asset-pack/` and update
  `tools/extract-assets-offline` imports.
- Make the extractor's normal destination the configurable external asset-pack
  store, with a generated `pack-*` identity and `Resources/manifest.json` as
  the completion marker. Preserve explicit output overrides.
- Remove checkout-relative generated `Resources` as a normal runtime search
  or output route.
- Keep `NOW_MIRROR_ASSETS` as the explicit override and the minimal host pack
  selector as the selection scaffold; never compile one pack ID or extraction
  path into the app.
- Preserve named absent-pack behavior and procedural fallbacks.
- Confirm no asset pack or generated resource tree is added to the active
  source package.

**Verification**

- Parser native tests pass from their new path.
- A no-write/list or temporary-output extraction smoke test proves the new
  path without modifying a disk image or the reference pack.
- Host and MirrorKit tests enforce pack-dependent assertions when a valid
  external pack exists and skip them by name when it does not.
- `git status` remains free of generated asset bytes.

**Commit boundary:** asset tooling and external-store policy only.

### U3. Archive the standalone Mirror project intact

**Goal:** Remove the copied product from active maintenance while preserving
its exact final state and provenance.

**Actions**

- Move the remaining complete `mirror/` tree to
  `archive/mirror-standalone-2026-08-09/`.
- Leave `archive/mirror-port-2026-08-01/` intact as the earlier imported
  snapshot.
- Add an archive note recording:
  - source lineage and final NOW commit;
  - why the standalone product was retired;
  - what production modules and tools were extracted, and their new paths;
  - which documents/findings contain the graduated conclusions;
  - that the archive is preserved but not built, shipped, or supported.
- Add a short archive lineage index distinguishing the August 1 import from
  the August 9 final snapshot.
- Update historical references to point into the archive where the raw source
  remains the intended evidence. Update active references to the new NOW-owned
  paths.

**Verification**

- `git ls-files mirror` returns nothing.
- No active manifest, Xcode project, script, test, or runtime source refers to
  `archive/` or the former root `mirror/` path.
- The archived snapshot still contains its root metadata, guest, extensions,
  host app, tests, tools, docs, and tracked asset copy.
- Repository gates do not traverse or build the archive.

**Commit boundary:** archive move, lineage note, and reference rewrites.

### U4. Graduate live research out of scratch space

**Goal:** Ensure the research remains discoverable without treating
`docs/local/` as published storage.

**Actions**

- Keep `docs/local/README.md`; it is the tracked policy door for the ignored
  scratch directory.
- Graduate these four tracked research artifacts into a deliberate published
  research location under `docs/research/mirror/`:
  - `018-lane-c-desktop-pattern.md`;
  - `toolbox-re/PLAN.md`;
  - `toolbox-re/ledger.json`;
  - `toolbox-re/prior-art.md`.
- Rename session-shaped titles where necessary so the published documents say
  what was learned, not merely what one agent planned to do.
- Update every script, probe, source comment, and plan that cites the old
  paths.
- Keep the detailed NOW-native research live, especially
  `docs/toolbox-and-gworld.md`, `docs/processes-and-peek.md`,
  `docs/mirror-crashes-now-on-metal.md`, and `docs/cursor-follow.md`.

**Verification**

- Only `docs/local/README.md` is tracked under `docs/local/`.
- All moved-document links resolve.
- The archive is not the sole location for any accepted technical conclusion.

**Commit boundary:** research graduation only.

### U5. Reconcile and extend the parent findings corpus

**Goal:** Preserve the expensive technical conclusions independently of this
branch and its archive.

**Parent baseline:** `codex/semantic-finder-finding` at `533d6f19`, currently
clean and 13 commits ahead of its `main`.

**Actions**

- Update moved source references in existing findings.
- Make the Finder/GWorld lineage explicit without deleting the earlier
  observations:
  1. Finder window ports expose opaque composite blits.
  2. The source offscreen GWorld can be found and yields labels/geometry in
     emulator experiments.
  3. transient-world birth interception through `_QDExtensions` is technically
     possible for InterfaceLib clients;
  4. the combined P3 tier is not metal-safe on the PB1400c;
  5. Finder's production boundary is semantic rendering with P3 permanently
     denied.
- Add or consolidate a focused A5 finding covering process-local Toolbox
  roots, resident anchor sampling, application-layer partition-bounded reads,
  `wrong-a5` refusal meaning, and why raw A5 is not a safe public selector.
- Add a cursor finding covering the distinction between low-memory mouse
  coordinates, Cursor Device Manager state, and the QuickDraw-drawn sprite;
  record `cursoract` as Tested but not yet baked or metal-verified.
- Preserve negative and retracted results. Do not rewrite the failed trap-patch
  control as if it never happened.
- Run the corpus validator, recording its pre-existing baseline separately and
  requiring no new failures from the changed findings.
- Commit corpus work separately in the parent repository and land it through
  that repository's normal main reconciliation.

**Verification**

- Changed findings parse and project.
- Every new claim has source, emulator, metal, or test evidence at the stated
  level.
- No finding cites the archived standalone tree as its only explanation.

**Commit boundary:** one coherent corpus closeout commit after any already
landed semantic-Finder finding series.

### U6. Close the NOW documentation ledger

**Goal:** Make the landed state understandable without reading the branch
history.

**Actions**

- Update `README.md` with both what Mirror currently does and what remains
  experimental, broken, or unverified.
- Close this arc in `docs/open-issues.md` without reorganizing unrelated
  history.
- Update `docs/mirror-knowledge.md`, `docs/mirror-foldin-inventory.md`, asset
  documentation, build instructions, and source maps for the new ownership and
  archive paths.
- Re-derive `docs/contract-coverage.md`. The archive move should not change
  served commands; any derived change must be investigated rather than
  hand-edited.
- Record at minimum these known boundaries:
  - Finder P3 permanently disabled;
  - fully emulated Finder experimental;
  - application P3 off by default and not generally metal-safe;
  - app-switcher behavior must be reported from the final run, not assumed;
  - Finder selection/view/drag limitations must be listed if still present;
  - cursor-only Finder follow is Tested but awaits baked/metal evidence;
  - the host launches with Mirror off.
- Add a short immediate-follow-on entry for remote cursor driving; do not
  implement it in this branch.

**Verification**

- Published links resolve and active docs contain no stale production paths.
- README claims agree with `docs/open-issues.md` and the actual final runtime
  receipt.
- Contract coverage remains derived and symmetric.

**Commit boundary:** NOW documentation closeout.

### U7. Run the deterministic release gates

**Goal:** Prove the structural cleanup did not alter behavior or silently
remove coverage.

**Order**

1. `git diff --check` and path/reference guards.
2. Parser and archive-layout tests.
3. `scripts/test-mirrorkit`.
4. Focused Host tests for Mirror startup, session teardown, Finder ownership,
   app-switcher projection, asset selection, and cursor follow.
5. `scripts/test-native`.
6. `scripts/build-guests`.
7. `scripts/test-host`.
8. `scripts/test-all` from a clean final tree.

Any new path/ownership guard must be mutation-proven: point a manifest or test
back at the archive and watch the guard fail before restoring it.

**Release blockers**

- Any production dependency on `archive/` or the removed root `mirror/` path.
- Mirror starting automatically on host launch.
- Finder reaching P3 through any supported target route.
- Stop, disconnect, or guest replacement retaining a prior Mirror session.
- A test or build that succeeds only because the asset pack happens to exist.
- A new contract or coverage asymmetry.
- Any regression introduced by merging current `main`.

**Allowed only when documented as known limitations**

- The explicitly labelled experimental Finder emulator remaining incomplete.
- Non-Finder application interiors remaining incomplete with P3 off.
- App switcher or Finder interactions that are still broken after the final
  acceptance run, provided README and open issues state them plainly and the
  default safe path does not crash or corrupt the guest.

### U8. Produce runtime evidence and bake the shared PPC image

**Goal:** Test and bake the exact final revision without disturbing another
session's machine or VM.

**Safe-default acceptance**

- Build and launch the final host; prove Mirror is off regardless of saved
  preferences.
- Establish exactly one guest connection identity.
- Start Mirror deliberately with Finder P3 denied and application P3 disabled.
- Exercise start, stop, reconnect, and guest replacement; prove each old
  session ends.
- Exercise Finder structure and semantic reads without automatic activation,
  `hide`, or `hideOthers`.
- Record whether desktop icons, Finder windows, selection, view changes,
  scrolling, dragging, app switcher, and cursor follow behave or remain known
  limitations.

**Application-content acceptance**

- Treat application P3 as a separate opt-in experiment, not part of the safe
  default soak.
- Never arm Finder.
- Do not blacklist Sherlock. If Sherlock is exercised, add mechanisms one at
  a time from a clean boot and report the result at the mechanism tier.

**Shared image bake**

- Inventory running QEMU processes and preserve all foreign/private clones.
- Only after U7 is green, bake with the repository's shared-image procedure
  (`NOW_STAGE_SHARED_FORCE=1 scripts/bake-ext-image --shared` when private
  clones are legitimately active).
- Record the source revision, guest and extension build stamps, resulting image
  path, hash/receipt, and whether the bake stopped cleanly.
- Boot a fresh session-private clone derived from the baked image and prove the
  expected guest identity and resident capabilities before testing behavior.
- A successful bake is not a metal result.

**Metal acceptance**

- Run the safe-default Mirror soak on the PB1400c with exact host/guest stamps.
- Require no Finder restart, no guest-app wedge attributable to Mirror, and no
  unexplained retained session.
- Record application P3 separately and do not let a successful Finder-safe run
  generalize to all application hooks.

**Commit boundary:** runtime evidence and final documentation corrections only;
the baked image itself remains a Lab artifact, not repository content.

### U9. Land and hand off

**Goal:** Make `main` point at the exact tested revision and leave the next
branch obvious.

**Actions**

- Confirm `main` has not advanced since U0. If it has, merge again and repeat
  affected gates.
- Build the final signed/notarization-appropriate local host artifact used by
  this project and record its path and revision.
- Require clean NOW and parent-corpus worktrees.
- Fast-forward or merge the finished branch into the shared checkout using the
  repository's worktree-safe procedure; leave the shared checkout on `main`.
- If moving the `main` ref without updating its working tree, resynchronize the
  clean shared checkout immediately and verify that no staged-deletion mirage
  remains.
- Tag the landed integration and record the tag, commit, full gate receipt,
  emulator image receipt, and metal status.
- Preserve the safety ref and archives until the landed revision has been used
  successfully; pruning them is a separate later decision.

**Follow-on branch:** cut remote cursor driving from the fresh landed `main`.
Its first gate is to metal-prove the existing `cursoract`/P8 route from the
baked image; only then generalize host pointer motion with coalescing,
correlation, human-yield behavior, and cursor-shape observation.

## Commit sequence

1. `merge: reconcile mirror integration with current main`
2. `refactor(mirror): extract NOW-owned MirrorKit libraries`
3. `refactor(assets): extract the asset-pack toolchain`
4. `archive(mirror): retire the standalone project`
5. `docs(mirror): graduate reverse-engineering research`
6. Parent corpus: `docs(findings): close the Mirror research lineage`
7. `docs(mirror): close the pre-merge ledger`
8. `test(mirror): enforce active-tree ownership boundaries` if new guards are
   not naturally included above
9. `docs(mirror): record final emulator and metal receipts`

Each commit must build or clearly identify itself as an unverified checkpoint.
Do not combine the main merge, package extraction, and archive move into one
unreviewable commit.

## Final checklist

- [ ] Safety refs recorded; source and parent worktrees clean.
- [ ] Current `main` merged; three known conflicts resolved semantically.
- [ ] `MirrorKit` and `MirrorKitUI` live under NOW ownership.
- [ ] `MirrorApp` and `MirrorOracleKit` are archive-only.
- [ ] Asset parsers live under NOW tooling; generated packs remain external.
- [ ] Complete standalone Mirror tree and lineage are archived.
- [ ] No tracked root `mirror/` tree remains.
- [ ] No production code, manifest, test, or gate loads from `archive/`.
- [ ] Scratch research is graduated and all links resolve.
- [ ] Finder, GWorld, A5, and cursor findings are reconciled in the parent
      corpus.
- [ ] README and open issues state experimental/broken/unverified behavior.
- [ ] Contract coverage is re-derived and symmetric.
- [ ] `scripts/test-all` passes from the final clean revision.
- [ ] Safe-default emulator acceptance passes with one connection identity.
- [ ] Shared PPC image is baked and verified from the final revision.
- [ ] PB1400c result is recorded at its actual evidence level.
- [ ] Final host artifact is built and revision-stamped.
- [ ] `main` points at the tested revision and the shared checkout remains on
      `main`.
- [ ] Remote cursor driving is handed off as the immediate next branch.

## Definition of ready to merge

The branch is ready when the active tree contains one NOW product with one
NOW-owned Mirror library package; the standalone project exists only as a
documented archive; the detailed and distilled research remains discoverable;
all deterministic gates pass; the final shared image has a reproducible
receipt; the safe default has not crashed or retained a session on the
PB1400c; and every remaining limitation is named plainly enough that landing
does not imply it was fixed.
