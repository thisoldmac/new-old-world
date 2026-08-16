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

Filled in as each batch resolves. See "Rulings" below.

## Rulings

_(populated during resolution)_

## Flagged for Michelle

_(files where the ruling was genuinely uncertain)_
