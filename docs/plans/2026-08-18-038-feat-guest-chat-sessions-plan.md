---
title: Guest chat grows a memory — sessions, projects, and three modes
type: feat
date: 2026-08-18
artifact_contract: ce-unified-plan/v1
artifact_readiness: experiment-gated
execution: code
---

<!-- now-doc-provenance: generated reviewed=false -->

# Guest chat grows a memory

## Goal Capsule

The classic machine's Chat page has exactly one conversation, it lives in
RAM on the modern Mac, and it dies with the connection — `ChatWireService.
sessionClosed` drops it. "New Chat" is `chat.reset`, which is a blank page,
not a second chat. Meanwhile the host's own Chat page has had saved chats,
a sidebar, and filing under projects since it shipped. The guest never had
any of it; nothing regressed, the feature was simply host-only.

This slice gives the guest the same three things, plus one the host does
not have yet:

1. **Many sessions**, listed in a collapsible sidebar inside the Chat
   page, persisted in the host's existing `ChatStore` so they survive a
   disconnect, a reboot of the classic Mac, and a relaunch of the app.
2. **Projects**: select one, create one, or work in none. Creating one
   asks the question that only exists in this product — **does this
   project live on the classic Mac or on the modern one** — which is the
   `ProjectHome` the Projects module already has and no face has ever
   offered from the guest.
3. **Chat / Plan / Build modes**, enforced by what tools the turn is
   given, not by what the model is told.

## Decisions taken (Michelle, 2026-08-18)

**The guest lists every saved chat, not only its own.** This REVERSES a
documented promise — `docs/user-guide/reference/modules/chat.md` said
saved chats "are never served to the classic guest" — and the reversal is
deliberate and must be written where a person reads it, not buried here.
The exposure it creates is real: a transcript typed on the modern Mac can
quote host-side work and can hold captured guest-screen images, and a
classic Mac sitting on a desk is a different exposure surface from a
laptop that locks. What makes it defensible is that both machines are the
same person's, the wire is already trusted with the machine's screen and
files, and a chat you cannot reach from the machine you are sitting at is
the reason people keep two chat windows open. Rows carry their ORIGIN so
the sidebar can say where a chat was typed.

**A mode is a gate, not a label.** Enforced host-side by filtering the
capability catalog for the turn:

| Mode | Tools supplied | The turn may |
| --- | --- | --- |
| Chat | every read-only row | look at anything, change nothing |
| Plan | every read-only row | look, and write a plan as its answer |
| Build | the whole catalog | write, apply, build, run |

Chat and Plan differ in instruction, not reach, and that is stated plainly
rather than dressed up: the difference a person feels is that Plan is
asked for a plan. The reach difference that matters — being unable to
change the machine — is real in both, and comes from
`HostProjection.mcpDescriptor`'s own `readOnlyHint`, which every row
already declares. **No new per-row metadata**: a mode that needed a second
table of what is safe would be a second place to be wrong, and the first
row added without a line in it would be silently writable.

## What ships, in slices

- **Slice 1 — the contract.** The family gains sessions, transcript
  paging, projects and a `mode` on `chat.send`. Additive, no revision
  bump, the `chat.models` precedent: a guest that asks an older host hears
  silence and says so.
- **Slice 2 — the host serves it.** `ChatWireService` stops keeping
  conversations in a dictionary and starts reading and writing
  `ChatStore`, which already has chats, chat-projects and a
  `linkedProjectID` pointing at a real `ProjectStore` project. Creating a
  project from the guest creates the real project with the chosen home and
  the chat-project that links to it — one act, two records, no third
  concept.
- **Slice 3 — the guest page.** A collapsible sidebar inside the one
  Workshop window, a mode popup, and the project row. Native controls,
  the rail's own list idiom, redraw ownership unchanged.
- **Slice 4 — the console face.** `CommandParityTests` fails the build if
  the page can do something the console cannot; sessions, projects and
  modes all get verbs.
- **Slice 5 — docs.** The module page, the reversed privacy sentence
  said out loud, and `docs/contract-coverage.md` re-derived.

## Slice 6 — the chat family reaches the MCP (Michelle, 2026-08-18)

**Decided against this plan's first instinct, and the instinct is recorded
because it was wrong.** The coverage gate caught `chat.roster`,
`chat.transcript` and `chat.projectroster` as undeclared gaps, and they
were first written up as DELIBERATE ones on the argument that a person's
saved conversations are not an agent capability. Michelle's answer:
*"this should be part of the mcp for sure — it's the agentic loop we're
trying to close right now."*

That is the stronger reading, and the earlier argument mistook a privacy
question for an architectural one. The person's own agent, running on
their own Mac against their own store, reading and continuing the
conversation they are having at the classic machine, IS the loop this
product is for. An agent that can drive the machine but cannot see or
answer the chat about it leaves the human as the only wire between the
two halves.

What the slice adds, in the order it should be built (**W6**, numbered so
`docs/mcp-coverage.md` can cite one item rather than a wish):

**W6 #1.** `now_chats` — one projection with an operation discriminant, the
   `now_projects` shape: `list` (paged), `read` (a transcript page, from
   the end, the same lazy rule the wire follows), `create`, `file`
   (under a project or none), and `projects` (the roster).
**W6 #2.** `append` — an agent writing INTO the conversation a person is having,
   which is the cheapest half of closing the loop and needs no model turn.
**W6 #3.** `send` — running a real turn, with the mode field the wire already
   carries. It is last because it is the only one that is long-running,
   and a local-socket call that can take minutes needs its own deadline
   argument rather than inheriting one by accident.

The plumbing is the `projects` path exactly: a method on
`AgentIntegrationClient`, a case in `AgentIntegrationLocalProtocol` with
its key set and well-formedness check, both clients, the host adapter,
then the projection and its catalog row. The store is already shared by
both faces, so nothing new owns the data.

**Until it lands, `docs/mcp-coverage.md` carries the three rows as
`planned`, citing this slice.** They are not deliberate gaps and must not
read as settled.

## Boundaries

- **Nothing about a chat crosses until it is asked for, and then in
  pages.** The roster is paged (cursor/more, the `chat.models` shape) and
  carries metadata only — never a byte of any transcript. Opening a chat
  transfers nothing by itself: the guest then asks for history a bounded
  page at a time, and a person who opens a long chat typed on the modern
  Mac pays for the lines they scroll to, not the whole thing. A classic
  ring holds 300 lines and a slow wire cannot afford an eager push.
- **A mode is per turn on the wire, remembered per session on the host.**
  One field, no synchronisation problem, no second verb.
- **NOW-68K is unchanged.** Chat is a PPC-asked family; the asymmetry is
  already declared.

## Verification

`scripts/test-all`, with the parity gate as the load-bearing one. Every
new guard watched failing against the mutation it names. Metal remains
unverified until somebody opens a saved chat on the PowerBook.
