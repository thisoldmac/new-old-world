<!-- now-doc-provenance: generated reviewed=false -->

# Reconciling `origin/main` into the continuity arc — 2026-08-16

`origin/main` (12d6dac8) and `refactor/mirror-continuity-split` (f9570f84)
share merge base `abdf8e42` (#26). Main carries three commits the arc
lacks; one of them, **#35 (b7fedae1), is a squash** of a 208-commit branch
that co-developed with this arc and was cross-picked from it in both
directions. `git merge origin/main` produces **118 conflicts**, 60 of them
`add/add` — the signature of the same file being created independently on
two branches that were exchanging picks rather than merging.

This page is the resolution log. Every conflicted file gets a ruling and a
one-line reason, because a merge this size resolved by side-picking is
indistinguishable from a merge resolved by reading, and only one of those
keeps eleven attended metal rounds.

## What #35 actually contains

Of #35's 208 squashed subjects, **45 have an equivalent commit in the arc's
own history** (matched by subject through `git log --grep --fixed-strings`
over `abdf8e42..f9570f84`) — the continuity rounds, the mirrorlog family,
the MCP host-log work, the share-root fix. Those are the cross-picks, and
for them main's content is *ancestral* to ours.

The remaining **163 are genuinely new to this branch**: plan 034's four
waves (guest citizenship / `describe_scene` / `copy_text`, the Files page
rebuild, Projects rename, Settings window, ChatStore), the **mirror-consent
contract change**, the **web proxy accept-by-bind fix**, census sizing,
`update_install`, the release DMG's Applications alias, and the CI fixes.

## The method

No file is resolved by picking a side. For each conflicted path the ruling
is decided by provenance:

1. **Ancestral test first.** For file `F`, is `origin/main:F`'s blob equal
   to `F` at *some* commit in `abdf8e42..f9570f84`? If yes, our lineage
   already contains theirs and has moved past it — **OURS**, decisively and
   cheaply.
2. **Continuity / drag lineage** (`Continuity*`, `continuity_*`,
   `now_continuity_*`, wire.c's continuity regions): default **OURS**, but
   only after diffing theirs against our history and carrying over anything
   ours never absorbed.
3. **Content the arc lacks entirely** (citizenship, mirror-consent, web
   proxy, census, `update_install`, `assemble-release`'s alias, the
   fileshare share-root rework): default **THEIRS**, integrated against our
   evolved neighbours. Seam compile errors get fixed, never deleted.
4. **`contract/asyncapi.yaml`**: union. Ours added `mirrorlog` and the
   continuity offer/drag act; theirs added mirror-consent.
5. **`ext/stage-receipts.json`**: resolved by asking the file — the oracle's
   actual sha256 via `tools/ext-bake-gate verify-image` decides, never a
   side.
6. **Derived docs**: markers cleared either way, then **re-derived** from
   the merged tree. A clean textual merge of a derived table is no evidence.
7. **`ext/` source**: none conflicted; had any, this stops for the human.

## Ruling table

| Ruling | Files | What it means |
| --- | --- | --- |
| OURS (ancestral, proven) | 30 | `origin/main`'s blob for that path is *byte-identical* to a blob this arc's own history already passed through. Main has nothing here we lack. |
| OURS (ruled) | 8 | Our lineage evolved past theirs and theirs carried nothing new. |
| THEIRS | 63 | Content the arc never had, or a decision main made *after* ours. |
| MIXED / union | 6 | Both sides added; neither is discardable. |
| Asked the file | 1 | `ext/stage-receipts.json`, decided by the oracle's own sha256. |
| Regenerated | 10 | Derived: markers cleared, then re-derived from the merged tree. |

118 conflicts. No file was resolved by preferring a branch.

### The ancestral test, and why it carried a third of the merge

For each conflicted path `F`, the set of blobs `F` ever held across
`abdf8e42..f9570f84` was enumerated and `origin/main:F` looked up in it. A
hit is not a judgement call: it says main's current content is a *snapshot
of our own past*, so ours contains it and has moved on. Thirty files
answered yes, and they are almost the entire continuity family —
`ContinuityEdgeController.swift` (42 revisions here), `ContractMessages.swift`
(34), `continuity_intake.c` (28), both `now_continuity_*` shared pairs, the
guest's `continuity_cursor`/`_service`/`_selection`, and their source tests.
Eleven attended metal rounds are on the far side of that test, and it cost a
script rather than a reading of each file.

### The other 88

Git had no merge base for 60 of the 118 (`add/add`) — the signature of two
branches creating the same file independently while cross-picking. For
those, the arc's **earliest** blob for the path was used as a synthetic
base and a real three-way merge run, which is only legitimate because the
creating commit is one of the shared picks. That collapsed ~350 raw
conflict regions to ~250 and, for fifteen files, to zero. Every remaining
region was read.

## Rulings

### OURS — the arc's lineage contains theirs and went further

`docs/continuity-mode.md` · `now-guest-ppc/src/input/continuity_cursor.{c,h}`
· `continuity_intake.c` · `continuity_selection.{c,h}` ·
`continuity_service.c` · `now-guest-ppc/tests/continuity_intake_lifecycle_source_test.py`
· `continuity_selection_gates_source_test.py` ·
`now-guest-shared/src/now_continuity_logic.{c,h}` ·
`now_continuity_selection.{c,h}` · `now-guest-shared/tests/` (five files) ·
`MirrorKitUI/PointerCapture.swift` · `AppKitContinuityPointerEnvironment.swift`
· `ContinuityDisplayLayout{,View}.swift` · `ContinuityEdgeController.swift` ·
`ContinuityFileDragWiring.swift` · `ContinuityFileEdge.swift` ·
`ContinuityHostModule.swift` · `ContinuitySelectionCache.swift` ·
`ContractMessages.swift` · `ContinuityDisplayLayoutTests.swift` ·
`ContinuityGuestDragTests.swift` · `MirrorContinuityControllerTests.swift`
— **ancestral, proven by blob identity.**

`now-guest-ppc/src/main.c`, `now-guest-ppc/CMakeLists.txt` (continuity
sources), `now-guest-ppc/src/core/wire.c` (three of four regions),
`commands.c` + `cmd_help.c` (`offer` verb), `HostAppState.swift`
(`selectionMark`), `FileTransferTests.swift`, `CommandParityTests.swift` —
the continuity.offer / Drag Manager half of the arc, which main has no
counterpart for at all.

`Session.swift` — all six regions. Ours refactored four inlined copies of
the file-get arming into `beginFileGet`; theirs still carries the four
copies. Ours also serves the inverted `continuity.grab` (the guest
redeeming a host offer) where theirs still refuses it as a
guest-can-never-collect violation. That refusal was correct until the offer
direction existed; the contract now declares `operations.guestReportsContinuity`,
so ours is the later reading of the same rule.

### THEIRS — content this arc never had, or a decision main made later

- **`scripts/assemble-release` + `tools/release-tests`** — the
  drag-to-install `/Applications` alias and the `diskutil image create`
  migration. Ours had nothing in these regions.
- **`now-guest-ppc/src/files/fileshare.c` + `update_install.c` +
  `trash_move.{c,h}`** — main *extracted our own* busy-move logic into a
  shared `now_trash_move_busy` and put `update_install` on it, which had
  independently re-derived the broken rename-first order. Theirs is ours,
  deduplicated, plus a second caller.
- **Settings window (G-5)** — `HostSettingsView`, `SettingsWindowController`,
  `App.swift`, `HostSidebarView`, and the per-module `openSettings` seams in
  `LogsHostModule`, `MCPHostModule`, `WebHostModule` and their views. The
  sidebar display menu and Web's "Page Compatibility" box moved *into* that
  window; verified present at their new homes before dropping them here.
- **Spring loading / drop geometry (H6/H7)** — `NavigationLayout`,
  `NavigationDragCoordinator`, `SidebarNativeDragSurface`,
  `SidebarNavigationContent`, `SidebarCanvasDropHost`, `ShelfDetailView`,
  and their four test files.
- **`prefs.{c,h}`** — theirs' `PrefsRecordV27/28/29` nest our own
  `PrefsRecordV26` unchanged, so theirs is strictly newer; V29 is the
  one-master-Mirror-consent record.
- **CI and naming sweeps** — `MachineNaming` interpolation
  (`MirrorAssetIngestion`, `MirrorFileTransferModel`, `GuestListener`,
  `ContinuityGrabTransfer`'s refusal sentence), `LocalizedStringResource →
  LocalizedStringKey/String`, the `super.setUp()` drop, and the test fixture
  that stopped naming a real desk (`/Users/michelle/Downloads` →
  `/Volumes/Scratch/Downloads`).
- **`development` → `projects` rename**, `census_size_mib`, `web_accept.c`,
  `web_proxy_ot.{c,h}`, `web_module.c`, ROM-dump `NSSavePanel`, and every
  user-guide page describing the moved preferences.

The one that most deserves naming: **`NavigationLayout`'s fixed shelf
heroes.** The arc added `fixedModuleHeroID`/`isFixedModuleHero`/
`enforceSpecialHeroes` on 2026-08-13. Main *removed* the whole concept on
2026-08-15 ("heroes are movable — hero is whatever the person put first"),
with its own ledger entry saying a drop in front of a pinned hero was
accepted and then silently undone. Newer decision wins; the dangling
`isFixedModuleHero` call left behind in `NavigationDragCoordinator` was
removed by hand.

### MIXED — both sides added, neither discardable

- **`contract/asyncapi.yaml`** — union. Ours contributes the whole
  `continuity.offer` family (message, schema, `acceptsOffer`, the inverted
  `continuity.grab` prose, `offer-expired`, the `offer` x-command); theirs
  contributes the master Mirror consent. Twelve regions, all ours-vs-empty;
  theirs' consent change landed in auto-merged text. Verified after: the
  file parses, and `mirrorlog`, `continuity.offer` and the master consent
  are all present.
- **`ConnectionsModel.swift`** — see "the most dangerous resolution" below.
- **`ConnectionsModuleView.swift`** — theirs, after confirming the security
  notice ours rendered inline (`trustedLANNotice`) had moved into main's
  `ConnectionLinkSection.swift` rather than been dropped.
- **`docs/open-issues.md`** — union of both ledgers. Nine arc sections, ten
  from 034/035; nothing merged textually clean, nothing dropped.
- **`scripts/test-native`** — ours' three new manifest entries
  (`now_continuity_offer_test.c`, `now_continuity_drag_test.c`,
  `continuity_dragmgr_source_test.py`, `continuity_deaf_logic_test.c`) plus
  theirs' `module_describe_scene_source_test.py`.
- **`now-guest-ppc/CMakeLists.txt`** — ours' continuity sources plus theirs'
  `trash_move.c` and `web_accept.c`.

### Asked the file

**`ext/stage-receipts.json`.** Ours holds 73 receipts, theirs 75 — the same
history plus #35's deferral and #36's shared bake. That alone would only
say "theirs is longer", which is a side pick wearing a reason. The oracle
itself was asked:

```
sha256 on disk   8db8ddc2de99c4221ba563ab095ebcb24190a4d3e7ef69ef0720edbdbba199d4
newest receipt   8db8ddc2...  (2026-08-15T16:09:10-0400, feat/034-host-guest-assessments)
VERDICT          MATCH. The oracle is the image this receipt describes.
```

The image on disk *is* #36's bake, so theirs is the file that describes
reality. Separately: `git diff f9570f84 origin/main -- ext/ contract/peek_table.h
contract/resident_version.h` touches nothing but the receipts file — **no
resident build input differs between the two sides**, so this merge carries
no bake obligation of its own.

### Regenerated, not merged

`docs/generated/asyncapi.md` (via `scripts/docs-contract`),
`docs/contract-coverage.md`, `docs/mcp-coverage.md`,
`docs/developer-guide/architecture/{resident-components,wire-contract}.md`,
`docs/developer-guide/workflows/build-and-test.md`,
`docs/user-guide/reference/{requirements.md,modules/index.md,modules/mcp.md}`
— markers cleared, then `tools/derived-doc-gate rederive` run over the
merged tree. It reported `sources` movement on all eight blocks. The
x-commands registry re-derives to **59** verbs, which is neither side's
number written down (ours said 59 with `offer`, theirs 58 without) but the
one the merged contract actually produces.

## The most dangerous resolution

**`now-host/Sources/Host/ConnectionsModel.swift`.** Both branches grew the
update-install path in the same weeks, in ways that touch the same three
functions and could each be made to look like the other's absence.

Ours added `pendingRelaunches` — a *machine*-keyed record of the build an
install was told to write, deliberately surviving the disconnect, because a
relaunch is only ever proved by a reconnect under a new `GuestKey`. Theirs
added a watchdog, a person's Cancel, a progress bar, and one rule holding
them together: whichever of the three endings reaches `finishUpdate` first
wins, and the later ones are late arrivals rather than second opinions.

Taking either side whole compiles and passes its own author's tests —
`ConnectionsModelUpdateTests` (ours) and `ConnectionsUpdateModelTests`
(theirs) are separate files and both survive the merge, so a side-pick here
would have failed a suite rather than gone quiet. The union was written by
hand: theirs' `guard pendingUpdates.contains(key)` and watchdog clearing
stay at the top of `finishUpdate`, and ours' `relaunchNotice(machine:...)`
replaces theirs' two fixed strings on the success branch, with
`pendingRelaunches` cleared on every failure path. `abandonUpdates` cancels
the watchdogs *and* keeps our comment explaining why `pendingRelaunches` is
untouched there.

That last comment is the part worth flagging: it explains an invariant
across a disconnect, and the merged function now has one more reason to run
than the arc's version did. It is tested, not watched.

## Flagged for Michelle

1. **`ConnectionsModel.swift`'s union** (above). Both suites pass, but the
   watchdog and the relaunch-confirmation record have never run in the same
   process before this merge. If an install ever reports "Installed, but NOT
   relaunched" *and* a timeout in the same breath, look here first.
2. **`docs/developer-guide/architecture/host.md`** now states (from main)
   that `continuity` is a registered module and that the Screen shelf
   contains it. That is main's fact; the arc's last docs commit was
   simultaneously "stop calling Continuity a Mirror mode". The docs gate
   checks it against the live registry and passes, so this is a note rather
   than a doubt.
3. **`docs/open-issues.md`'s ordering.** Nineteen new sections from two
   branches, appended in two blocks rather than interleaved by date. Nothing
   is lost; the reverse-chronological reading is approximate for
   2026-08-14/15.
4. **The brief's second "metal-bitten fix main has that the arc lacks" was
   not one.** `fileshare.c`'s share-root rework (`now_files_share_root`,
   the `prefs.share_dir > 0 ? … : fsRtDirID` reachability check) is
   **byte-identical on both sides** — commit `4c909fa9` carries it in this
   arc's own history. What actually differed in that file was the
   `trash_move` extraction. The `/Applications` alias half of the brief was
   correct and is restored.
