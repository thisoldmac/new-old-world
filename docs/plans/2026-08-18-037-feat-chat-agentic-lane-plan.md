---
title: Chat with hands — honest tool reach, the whole registry, and a workspace lane
type: feat
date: 2026-08-18
artifact_contract: ce-unified-plan/v1
artifact_readiness: experiment-gated
execution: code
---

<!-- now-doc-provenance: generated reviewed=false -->

# Chat with hands

## Goal Capsule

The Chat page is already an agentic loop over the whole host projection
registry, and on 2026-08-18 it read to its own author as a chatbot that
could not see the machine it was sitting on. Three separate causes, one
symptom.

1. **The provider the person picked had no hands and said so in
   sentences.** `Claude (Experimental)` spawns the `claude` CLI with
   `--tools ""` and a literal "Do not use tools."; Codex spawns with
   every tool disabled. Two of the six providers are text-only relays
   and **nothing in the popup says which** — so the model picker is
   silently a choice between an agent and a chatbot.
2. **The project/build/run tools were behind a keyword sniffer.**
   `ChatDevelopmentContext` supplied `now_projects`,
   `now_development_environment` and `now_development` only when the
   person's own words contained one of thirteen hardcoded terms. Ask for
   "a thing that beeps" and the model correctly reports it has no
   project tools.
3. **Nothing in the registry reaches New Old World's own source.** Every
   capability's authority domain is the guest plus the app's bounded
   Projects storage. Developing NOW itself from its own Chat page — the
   thing asked for — was not a gap in chat but outside the declared
   authority of every row in the catalog.

The lesson is the same one this repository keeps paying for in other
places: **a face that cannot do a thing must say so where the person
chooses, not in a paragraph after they have asked.** A tool-less
provider presented identically to an agentic one is the chat-shaped
version of a gate that reads green having reached nothing.

## What ships

**A. Tool reach is a property of the provider, declared and shown.**
`ChatProvider` gains `toolReach`: `.harness` (the harness renders the
registry and runs the loop), `.workspace` (the provider runs its OWN
agentic loop and reaches NOW through MCP), or `.none(reason:)`. The
harness reads it rather than assuming, the system prompt is composed
from it so a tool-less turn tells the model it has no hands, and the
reason travels in the provider entry's `detail` — the field the guest's
popup already draws, so the classic machine learns it too with no
contract change.

**B. The whole registry, every turn.** The keyword sniffer is deleted.
All forty rows are supplied; the project-authority paragraph is stated
unconditionally.

**C. The workspace lane.** `Claude (Experimental)` becomes a real
agentic lane when — and only when — a person points it at a directory.
The spawned CLI gets its own file and shell tools with that directory as
cwd, **plus New Old World's own MCP server** (`--mcp-config` naming this
executable's existing `--mcp-stdio` mode), so one turn can read
`now-guest-ppc/src/chat/chat_module.c`, run `scripts/build-guests`, and
drive the connected classic machine. Off by default, configured in
Settings, and honest about what it is: the CLI's own tools are governed
by the CLI's permission mode and the repository's own hooks, **not** by
the projection registry's consent tiers and audit — the NOW half of the
turn is audited exactly as before, the file-and-shell half is not.

## Boundaries

- Codex stays text-only this pass. It is sandboxed by its own client and
  un-clamping it is a second, separate authority argument; it gets the
  honest label from A, not a lane.
- The lane is a **host-side** authority. It grants a coding agent a
  directory on the modern Mac. That is a bigger grant than anything else
  in this application and it is stated in those words in Settings.
- No contract change. `chat.status` already carries what a tool is
  doing; the lane's activity rides it.

## Verification

- `scripts/test-host` for the suites and both app builds.
- The lane's argument construction and its stream parsing are unit-tested
  against real recorded `stream-json` lines, not invented ones.
- Metal remains unverified until someone drives it from the PowerBook.
