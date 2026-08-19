---
page_id: chat-module-reference
title: Chat module
description: Use a model provider on the modern Mac from the PowerPC Workshop while preserving provider, model, access, and cancellation state.
doc_type: reference
audience: user
lifecycle: experimental
authority: [contract/asyncapi.yaml, docs/agent-integration.md]
module_ids: [chat]
source_dependencies: [contract/asyncapi.yaml, now-host/Sources/Host/ModuleRegistry.swift, now-host/Sources/Host/Chat/ChatStore.swift, now-host/Sources/Host/Chat/ChatWorkspaceLane.swift, now-guest-ppc/src/chat, docs/agent-integration.md]
media_ids: [chat-host, chat-ppc, chat-detail]
last_verified: 2026-08-18
---

<!-- now-doc-provenance: generated reviewed=false -->

# Chat module

## What it does

Chat lets the PowerPC guest ask a model harness on the modern Mac. Provider and
model references are host-minted and the conversation can include only the
machine context the current grant permits.

![The macOS Chat provider and model surface](../../../assets/screenshots/modules/chat/host.svg){ .now-placeholder }

## Availability

Chat is a host-served, PowerPC-asked family. NOW-68K does not expose it.

## What a model can reach

Not every provider can act. Four of them (Anthropic, OpenAI, and the local
Ollama, LM Studio and oMLX runtimes) are given New Old World's own tools and
can observe and drive the connected classic machine. Two of them — Claude
(Experimental) and Codex — are runtimes this app drives as a subprocess with
their tools disabled, and can only answer from knowledge.

Which one you have picked is shown in the provider's own description, in both
the macOS popup and the classic machine's page, and the model is told the same
thing — so a model without tools says it cannot look rather than promising to.

The classic machine's Chat page goes further: a provider's reach travels
with its catalog row, so picking a text-only one dims the mode popup
instead of offering you Build for a model that cannot build.

## The chat workspace (experimental)

Settings > Chat can point Claude (Experimental) at **one folder on the modern
Mac**. That turns it into a coding agent: it gets its own file and command
tools inside that folder, and — unless you turn it off — New Old World's
capabilities alongside them, so a single conversation can read source, build
it, run the tests, and drive the classic machine to try the result. It is how
New Old World's own guest software can be worked on from the classic Mac's own
Chat page.

Two things to know before turning it on:

- **The folder's tools are not this app's tools.** Everything else Chat does
  goes through capabilities New Old World owns, logs on the Logs page, and
  gates by the machine's consent setting. The workspace's file and command
  tools do not: they are governed by the mode you choose ("Edit files", or
  "Edit files and run commands") and by whatever policy that folder carries.
- **It applies to that one provider.** Models chosen from any other provider
  are unaffected.

## On the modern Mac

The host owns provider configuration, model catalog, authentication, request
execution, and typed errors. Provider credentials never cross the classic wire.

Chats are saved on the modern Mac and listed in a sidebar beside the
conversation. A chat can be renamed, deleted, or filed under a project — a
folder on disk that may also be associated with a Projects-module project for
its code. Only the chat you select is read from disk; the sidebar itself holds
names and dates alone. The files stay on the modern Mac and are never uploaded
anywhere; they can be READ from the classic machine's own Chat page, which is
the deliberate 2026-08-18 change described above.

## Saved chats, on both machines

Chats are saved on the modern Mac and listed in a sidebar beside the
conversation — and since 2026-08-18 the classic machine can list and open
them too, its own and the ones typed at the modern Mac alike. Every row
says which machine it was typed at.

**This is a deliberate change to what the classic Mac may see.** Until
that date this page promised that saved chats were "never served to the
classic guest". They now are, on request, because a chat you cannot reach
from the machine you are sitting at is the reason people keep two windows
open. What that widens is real and worth knowing: a transcript typed at
the modern Mac can quote work done there and can hold captured
guest-screen images, and a classic Mac sitting on a desk is a different
exposure surface from a laptop that locks itself.

Nothing is sent before it is asked for. The classic machine receives a
page of TITLES — never transcript text — and opening a chat transfers
nothing by itself; the page then asks for what was said newest-first, a
bounded page at a time, so opening a long conversation on a 68030 costs
the lines you scroll to rather than the whole thing.

## Working in a project

A chat can be filed under a project, or under none. Creating one from the
classic Mac asks the question this product exists to ask: **does the
project live on this machine, or on the modern one?** The console spells
it `here|there`.

Answering "here" files the chat and records that the code belongs on the
classic Mac. The code half arrives by the existing staged-and-promoted
path rather than being created on the spot: a guest-home project is
authoritative on the classic machine and requires a verified digest, so
New Old World will not mint one behind your back and call it yours.

## Skills

New Old World ships the classic Mac development skill tree — eight
skills covering Carbon and Toolbox UI, the platform layers, INITs, the
emulator harness and render previews. They are instructions, not tools:
loading one puts its rules in front of the model for the rest of the
conversation.

Type them like any other message, at either screen:

| Command | What it does |
| --- | --- |
| `/skills` | list what is installed, with a sentence each |
| `/classic-mac-carbon-ui` | load that skill for this conversation |
| `/classic-mac-carbon-ui how do I draw a tab?` | load it and ask, in one go |

The model is always told which skills exist so it can suggest one, but it
cannot load a skill itself — that stays a decision you make. A loaded
skill governs craft; it cannot widen what the turn may touch, because the
machine and consent rules are stated after it and win.

Skills matter most in Build mode with project tools: without them a model
will write a UPP as a cast and skip pumping the wire inside a nested
Toolbox loop — mistakes that compile cleanly and misbehave only on the
real machine.

## Chat, Plan and Build

Every turn runs in one of three modes, and the mode decides which tools
the model is given rather than merely what it is told:

| Mode | What the model may do |
| --- | --- |
| Chat | look at anything — processes, screen, files — and change nothing |
| Plan | the same, and answer with a plan rather than an action |
| Build | everything, including writing files, applying project changes, building and running |

Chat and Plan reach exactly as far as each other; the difference you feel
is what the model is asked for. Build is the only mode whose turn is
handed a tool that can change the machine.

## On the classic Mac

The Workshop page selects a host-provided model reference, sends a prompt, and
renders deltas, status, result, cancellation, and reset.

Down its left side is the saved-chats list, which collapses with the
button beside the mode popup to give the conversation the full width.
Each row marks where that chat was typed — `*` for this machine, `-` for
the modern Mac — and selecting one opens it, filling the page from the
newest end as far back as you scroll.

![The PowerPC Chat page](../../../assets/screenshots/modules/chat/ppc.svg){ .now-placeholder }

## Common tasks

- Select a provider and model only after their catalogs arrive.
- Cancel a reply from the visible conversation bracket.

![A streaming reply with cancel visible](../../../assets/screenshots/modules/chat/detail.svg){ .now-placeholder }

## Safety, consent, and privacy

Prompts and supplied machine context may leave the modern Mac when a cloud
provider is selected. Saved transcripts are stored unencrypted under the app's
Application Support folder and may include captured guest-screen images. MCP access remains a separate machine consent ceiling;
Chat cannot silently expand it.

## Failure states

Provider unavailable, model stale, not granted, cancelled, reset, and provider
error retain separate status.

## Current limitations

Chat availability depends on a configured host harness. It is not an offline
guarantee and has no 68K UI.

The classic machine's Chat page draws the saved-chats list, the mode
popup and the project popup, and the same capabilities are reachable
from the Console (`chat --chats`, `--open`, `--history`, `--projects`,
`--project`, `--mode`) — the parity `CommandParityTests` enforces. None
of it is metal-verified.

The workspace lane is experimental and **not metal-verified**: it has been
exercised by the host suites only, and nobody has yet driven a build of the
guest from the guest's own Chat page.

## For developers

See [agent boundary](../../../developer-guide/architecture/agent-boundary.md)
and the [wire contract](../../../developer-guide/architecture/wire-contract.md).
