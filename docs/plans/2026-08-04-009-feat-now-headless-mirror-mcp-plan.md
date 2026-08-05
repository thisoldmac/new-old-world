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

### Slice 5 — the control-panel corpus, and the gap ledger

**Parity is a floor, not a ceiling, and this is the slice that says so.** The
renderer and MCP read the same IR; if the producer never captured a list's
cells, both faces are equally blind and perfect parity hides it. The walls this
project keeps hitting — lists, custom draws, whole classes of element — live
one layer BELOW both faces, and no amount of slice 1–4 work reaches them.

Open roughly ten control panels and capture each one three ways, at the same
moment:

- the **guest framebuffer** (QMP screendump) — what the machine is showing;
- the **MCP snapshot** — what the IR carries;
- the **oracle memory read** — what is actually in the heap.

Two diffs fall out, and they answer different questions. Screendump against
snapshot says *what we fail to show*, which is the UX gap the drive loop has
been scoring by eye. Snapshot against memory says *which layer lost it* — the
structure existed and the producer dropped it, or it was never there. Without
the second diff an enumeration is a list of complaints; with it every row
arrives already assigned to producer work, honesty work, or deferred-forever.

Control panels are the sample for the reason rung 3 gives: they are identical
on every OS 9 machine, so a captured scene is a permanent regression fixture in
a way "whatever was open that day" never is. Capture them **garbage and all** —
Mirror's corpus rule is explicit that a corpus of only healthy scenes tests
nothing.

Pick for **variety of control class**, not for ten panels: Extensions Manager
(the best real list on the machine), Monitors and Sound (lists and sliders),
Appearance (tabs, colour swatches), TCP/IP (multi-character tab-linked fields),
Date & Time (radios, steppers, and rows already scored red), File Sharing
(fields, a list, live state), Keyboard (popups), Memory (radios, sliders),
Internet (many fields, tabs).

Three rules the capture tool must enforce rather than ask anyone to remember:

- **One moment.** The machine moves between reads, and a diff across two states
  is noise wearing the costume of a finding. Same discipline as the paired
  screendump rule.
- **Target frontmost.** Occlusion is a skip and never a pass; the structure read
  does not care, the pixel comparison does.
- **Provenance on every capture** — guest build, resident build and plane bits,
  snapshot id and generations. Slice 4's read rows exist to supply exactly this,
  which is why they come first.

The output is a ledger with a fixed vocabulary per gap, or it will not survive
being read a week later: **which layer** (producer / IR / client), **which
class** (readable structure, custom-drawn, composited art), and **the honest
interim behaviour**. That last column is what makes the follow-up metal-friendly
work rather than a wish list: a gap with no reading path still has a correct
answer, which is to say so in the data rather than draw something plausible.

One finding is already in hand and shapes the ledger's first rows.
`Scene.Semantics` carries `listCells` and `listTotalCount` today — the IR has
had a place for list rows all along, so for lists the producer is the whole
problem and layer 2 is fine. And `knowledge` (`known`/`unknown`/`truncated`/
`stale`) plus `completeness` already exist, so a producer that admitted "I saw
a control here and could not determine its kind" would make the coverage gap
visible in the data instead of inferred from a bad-looking render. That is the
cheapest move in this whole arc and it introduces no new mechanism.

### Slice 6 — close the gaps, metal-first

Ordered by the ledger's own classes:

- **Readable structures the producer does not walk** — `ListRec` cells,
  `TERec` bodies, popup menu contents. Ordinary work: read a documented
  structure, fill a field the IR already has.
- **Honesty for what cannot be read** — emit `unknown`/`truncated` rather than
  a plausible default, so the Mirror declines to draw what it does not know.
- **Custom-drawn and composited art** — deferred, and stays deferred. Rung 5
  holds QuickTime Player to the honesty bar for this exact reason.

**Two oracles, two jobs, and the split is load-bearing.** QEMU memory reading
DISCOVERS layout — one-off, when nobody yet knows what a structure looks like
on this OS version, or whether one exists at all. That "does a structure exist
here" question is what decides between a walk and an honest refusal, and it is
the highest-value thing the emulator can answer. A guest-side probe SURVEYS
coverage — what the resident found, interpreted, and could not read — over the
wire, on metal, with no emulator involved. Surveying must not depend on QEMU or
the coverage question becomes unanswerable on the PowerBook, which is the one
machine where it matters.

And the oracle is an instrument, so it is the first suspect: a two-byte width
error in a probe's own filter once produced two opposite wrong conclusions from
one bug in this project's history. Cross-check anything it reads against the
guest's own view of the same window before an offset reaches a walk.

## Ordering, and why it is not the obvious one

Metrics first because they are the point of a headless round and cost least.
The snapshot before the executor because it is what makes MCP a *mirror* rather
than a summary, and because it surfaces the ref gap the executor needs closed.
The rows last because every one of them is a day's work on the current split
surface and an hour once the executor is shared.

Slices 5 and 6 come after all of that and are a different KIND of work: 1–4
make the two faces one product, and 5–6 widen what either face can see at all.
They are appended rather than woven in because they depend on the whole of
1–4 — the corpus's provenance comes from slice 4's read rows, its structure
comes from slice 2's surfaces, and opening ten panels to capture them is
slice 3's drive path doing the opening.

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
