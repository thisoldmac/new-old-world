---
title: New Project chooses its ground — home and toolchain as one decision
type: feat
date: 2026-08-19
artifact_contract: ce-unified-plan/v1
artifact_readiness: experiment-gated
execution: code
---

<!-- now-doc-provenance: generated reviewed=false -->

# New Project chooses its ground

## Goal Capsule

The agentic loop closed on 2026-08-19 with the WRONG default made
visible: the demo built on the modern Mac with Retro68 and shipped a
binary over, and Michelle's correction names the product's actual
shape:

> A big part of this is building *on* the guest using MPW toolchain,
> which we're now offering as part of the setup image. Maybe this
> should be an option, like New Project -> Project Location:
> * On {This Mac / Guest} using {Configured toolchain} (stores project
>   files on the guest, host keeps a copy or diffs for the agent to
>   iterate against rapidly, but builds are sent to the guest and
>   built on it directly)
> * On {This Mac / Host} using Retro68 (project files stored on host,
>   builds done using Retro68 and binaries sent to the guest)
> Both accessible from either guest or host chats.

The surprising finding (mapped 2026-08-19): **both lanes already run.**
Guest-home MPW build/run is metal-verified (PB1400c, 2026-08-09) and
the full guest-toolchain agentic loop is emulator-verified
(`feat/mpw-starter-pack`, 2026-08-19: candidate sealed, MrC/PPCLink/Rez
3 of 3, exact-product run receipt). Host-side Retro68 → binary → guest
is the workspace lane, emulator-verified on `feat/agentic-loop`. What
never shipped is the DECISION: no face lets a person (or an agent)
choose a project's home and toolchain, and every host-created project
is unbuildable by construction.

## The four real gaps

1. **No home choice reaches a real project.**
   `AgentIntegrationSessionHealth.swift:414` hardcodes `home: .host`;
   `AgentIntegrationProjectRequest` has no home field; the host
   Development sheet is titled "New Host Project"; the chat sidebar
   button creates a folder literally named "New Project". The guest
   chat dialog DOES collect here/there (this branch) — but
   `ChatServices` stores it only as `ChatProjectRecord.intendedHome`,
   an aspiration on a chat folder.
2. **The chat-project ↔ ProjectStore seam is dead code.**
   `ChatProjectRecord.linkedProjectID` and `ChatStore.associate` are
   called from nowhere; only a sidebar badge reads the field.
3. **No project ever gets a real toolchain pin.** Both templates emit
   `toolchain=unselected@0`; the guest refuses `toolchain-pin-mismatch`
   against its measured `mpw-<id>@structural-1`, and the agent template
   emits no `build-action` lines at all (`build-plan-empty`). Nothing
   in the product writes a pin that builds.
4. **Toolchain is not a concept anywhere** — one implicit guest MPW,
   one implicit host Retro68 known only to the workspace lane's shell.

## Ships

### A. The decision, modeled once (contract + agent surface)

- `AgentIntegrationProjectRequest.create` gains `home` ("host"|"guest")
  and `toolchain` (an opaque choice token, below). `ProjectsProjection`
  schema follows; `AgentIntegrationSessionHealth` routes it instead of
  hardcoding `.host`.
- `chat.project create` already carries `home` on the wire (038's
  work + this branch's dialog). It stops dead-ending in
  `intendedHome`: the create path mints a real `ProjectStore` project
  and `associate`s the chat folder with it — the dead seam wired, not
  a new one.

### B. Toolchain becomes a pin a build can pass

Two values, deliberately not a registry:

- **`guest-mpw`** — resolved at create time by asking
  `now_development_environment` for the guest's measured id+version
  (`mpw-<vref>-<dir>@structural-1`). Refused with the guest's own
  vocabulary when nothing is registered/qualified ("Register MPW
  Folder on the classic machine first"). The pin records what the
  GUEST measured, never a host guess.
- **`host-retro68`** — a sentinel pin (`host-retro68@1`) marking a
  project the workspace lane builds; the guest never sees a build for
  it, so it can never mismatch. Requires a configured chat workspace
  lane (that is where Retro68 reach lives), and the refusal says so.

Templates stop emitting `unselected@0`; the agent template gains the
`build-action` lines it always needed. **Contract first** if any wire
shape changes; `docs/contract-coverage.md` re-derived in the same
commit.

### C. Guest-home create keeps the store's honesty

`ProjectStore.create` keeps refusing a guest-home mint without a
verified guest digest — that refusal is the authority story. "New
Project on the guest" is therefore a two-step the UI narrates rather
than hides: scaffold on the guest (or host-home + workspace), then the
existing `import` path establishes the digest and the linked project.
The host workspace mirror (open/apply/promote, digest-guarded) is
unchanged — it IS the "host keeps a copy or diffs for the agent to
iterate against rapidly" from the goal capsule.

### D. Two faces, one dialog shape

- Host Development create sheet: title loses "Host"; gains the
  location+toolchain picker in Michelle's words — "On <guest name>,
  using MPW (as registered on it)" / "On this Mac, using Retro68".
- Guest chat New Project dialog (this branch): gains the toolchain
  line; its radios already choose home.
- Host chat sidebar's button gets the same sheet, not a bare folder.

### E. The three loop debts lane 1 already owes

- `stage` refusal returns the minted candidate ID (open-issues:7132) —
  today a failed stage leaves unaddressable guest residue.
- Guest-home `promote` exercised once on the emulator (explicitly
  excluded from every verification so far).
- The pin-vs-tools finding stands recorded: the pin proves the
  registration, not the tools that ran (open-issues:7380). Not fixed
  here; not silently forgotten either.

## Boundaries

- `exec.request` stays human-console-only; agents keep the typed verb
  plane. Building on the guest is `development-build` via ToolServer
  AppleEvents, as shipped.
- No toolchain registry, no third pin value, until a second real
  toolchain exists on a real machine.
- Promotion digest guards are never relaxed for convenience; a
  divergent guest stays a refusal with a story.

## Order

A and B are one workstream (the decision threaded through), C rides
the existing import path, D is two small UIs over one new argument,
E is cleanup the loop already owes. A/B first — nothing else is honest
until a created project can build somewhere.
