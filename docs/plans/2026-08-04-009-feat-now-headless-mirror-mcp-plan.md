---
title: The headless Mirror — NOW MCP as the Mirror's second client - Plan
type: feat
date: 2026-08-04
---

# The headless Mirror — NOW MCP as the Mirror's second client - Plan

## Goal Capsule

- **Objective:** Make the NOW MCP a complete headless client of the Mirror's
  state engine, so that everything a person can read off the Mirror window and
  every mutation they can drive through it is equally available to an agent —
  differing only in pixels and input method.
- **Authority:** `MirrorStateEngine` is the single source of published state.
  `MirrorActionExecutor` and the mutation broker are the single mutation path.
  Neither face may mint its own cache, its own addressing grammar, or its own
  settlement rule. `contract/asyncapi.yaml` still owns guest-wire meaning; none
  of this work adds a guest message.
- **Execution profile:** Additive projections inside the existing NOW MCP
  surface (`HostProjectionCatalog`). No second server, no new transport, no new
  executable, no MCP-only code path to the guest.
- **Stop conditions:** Stop if a slice requires MCP to reach the guest by a
  route the Mirror window does not use; if it requires a second scene cache; if
  it would settle a mutation on dispatch rather than observation; or if it
  needs a guest contract change (that is a separate arc, contract-first).
- **Tail ownership:** With MCP present or absent, the Mirror window behaves
  identically. Every projection added here reads or drives what the window
  already reads or drives.
- **Handoff status:** Slices 0–3 are implemented, gate-green and proven over
  a live socket against an emulated Power Mac G4. The first MCP-driven act,
  2026-08-05: `activate` against the published `process:process-ffc0941c`
  settled `confirmed` — waited 0 ms, dispatch 112 ms, settle 46 ms — and the
  Finder came front with its Macintosh HD window. It appears in
  `now_mirror_metrics` as `click Finder`, the same label and the same clocks
  the Mirror page's Acts card shows, which is the invariant this arc exists
  to establish. Still owed: the paired hand-versus-MCP comparison (§
  Verification), and slice 4.

---

## Why this arc exists

Two things forced it, both on 2026-08-04.

A metal drive of the PowerBook 1400c produced ~45 acts, no confirmed
settlements, and no way to tell a working-but-slow act from one queued behind
an act that was going to time out. The measurements that answer this now exist
(`MirrorActClocks`, `MirrorCycleClocks`) but they were born visible only in
NOW's own Mirror page.

And taking the parity inventory ([mirror-mcp-parity.md](../mirror-mcp-parity.md))
turned up something worse than missing rows: the two faces do not share an
implementation. A person's gesture goes scene object → `MirrorActionExecutor` →
`InteractionPlan` → broker → typed settlement. An MCP act goes an opaque
`now-element-…` ref straight to the guest's command dispatch, settling for
nothing. **An agent benchmarking through MCP today measures a path no person
can take.** Adding rows on the current MCP side would deepen that split, which
is why the ordering below is not the obvious one.

## The invariant

> The Mirror window and the NOW MCP are two clients of one state engine. The
> only differences are pixels and input method.

Three consequences, and every slice below is one of them:

1. **Anything the renderer reads, MCP can read.** So an agent can pull the
   data, confirm the state is actually there, and only then implement the
   render — instead of inferring from pixels it cannot see either.
2. **Anything a gesture can do, a call can do**, through the same executor,
   returning the same operation record and settling the same way.
3. **Anything the page displays about itself** — planes, resident identity,
   the journal, the clocks — is readable headless.

## Slices

### Slice 0 — metrics (done, unproven live)

`now_mirror_metrics`: both clock families and the lane depth. Landed at
`cafa61e`. Metrics answer even when no scene has arrived (a declined or
timed-out walk is exactly when the numbers matter); an absent measurer is
`unavailable` rather than an empty list; and the read never constructs the
Mirror, or asking what was measured would create the measurer and return an
empty answer that reads like a quiet machine.

**Owed:** one end-to-end call over the agent socket. Until then this is
*tested*, not *works* — the distinction AGENTS.md asks for.

### Slice 1 — prove the socket, and give the arc its harness

A small host-side client that speaks the agent unix socket
(`$TMPDIR/dev.newoldworld.now-agent-<uid>/host.sock`), so every later slice can
be verified headless rather than by eye. This is also the benchmark driver:
scripted, repeatable, and — once slice 3 lands — driving the same path a hand
does.

Done means: `now_mirror_metrics` answered over the socket from a live host, and
the reply's numbers match the Mirror page's for the same moment.

### Slice 2 — the snapshot carries the renderer's whole input

Today `now_mirror_snapshot` carries process and window *entities*, coverage and
the menu bar. It does not carry window rects or z, controls (kind, title,
value, rect, enabled, ref), dialog items, desktop items, screen size, or the P3
content plane. Those are exactly the things the drive loop scores — a field
whose value is missing, a checkbox drawn as a push button, a label truncated
mid-word — so the render workflow in consequence (1) is impossible today.

Projected from the same engine snapshot the renderer composes from, so the two
cannot disagree.

**This slice will expose, not cause, a Mirror-side defect:** `Scene.Control.ref`
is empty from NOW's producer. The window hides it behind positional resolution;
an agent will be able to see a control it cannot name. Record it, do not paper
over it — slice 3 depends on it.

### Slice 3 — one executor behind both mutation faces

`now_mirror_act` builds an `Interaction` against scene-object identity, runs it
through `MirrorActionExecutor` and the broker, and returns the `MirrorOperation`
— id, outcome, reason. Settlement arrives from a later observation exactly as
the window's does; the caller polls for the settled record (the existing
`now_mirror_wait` shape, or an operation-scoped sibling). Async submit, same
answer the UI gets.

A dispatch still may not claim an effect. That rule is older than this arc and
survives it.

### Slice 4 — the remaining rows

Cheap once slice 3 exists, and mechanical:

- mutate: `keystroke`, `typeText`, `dialogItem`, `applicationVisibility`
  (Hide / Hide Others / Show All), `openAppleMenuItem`, `finderSelect` /
  `finderOpen` / `finderDeselect`, `activateWindow` as one operation
- read: plane policy and the capability/requested/active bits, resident
  identity and build fingerprint, the operation journal

Resident identity is worth its own line: on 2026-08-04 a PowerBook with an old
`Now Extension` beside the new `NowExt` answered from the stale one, every act
refused as *the anchor plane is absent or not armed*, and the host knew the
resident's build the whole time without saying it.

## Ordering, and why it is not the obvious one

Metrics first because they are the point of a headless round and cost least.
The snapshot before the executor because it is what makes MCP a *mirror* rather
than a summary, and because it surfaces the ref gap the executor needs closed.
The rows last because every one of them is a day's work on the current split
surface and an hour once the executor is shared.

## What would make this arc wrong

- Any slice that gives MCP its own way to reach the guest. Then the two faces
  diverge again and every measurement taken here describes the wrong product.
- Settling a mutation on dispatch to make the headless path feel responsive.
- Treating the emulator's numbers as metal's. Behaviour transferred from
  emulator to metal on 2026-08-04; timing did not, and one metal run is one
  machine's anecdote until it is repeated
  ([mirror-measurement-method.md](../mirror-measurement-method.md), rules 1–2).

## Verification

Each slice: focused host tests, watched fail by mutation, plus one headless
call proving the row answers live. Slice 3 additionally needs a **paired**
check — the same mutation driven once by hand through the Mirror and once
through MCP, producing the same operation record and the same settlement.
That pairing is the proof the two faces really are one implementation, and it
is the only test in this arc that cannot be automated away.
