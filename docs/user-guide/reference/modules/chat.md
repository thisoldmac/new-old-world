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
names and dates alone. Saved chats stay on the modern Mac: they are never
served to the classic guest, and a transcript can contain what the classic
Mac's screen looked like, so the files are local and unshared.

## On the classic Mac

The Workshop page selects a host-provided model reference, sends a prompt, and
renders deltas, status, result, cancellation, and reset.

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

The workspace lane is experimental and **not metal-verified**: it has been
exercised by the host suites only, and nobody has yet driven a build of the
guest from the guest's own Chat page.

## For developers

See [agent boundary](../../../developer-guide/architecture/agent-boundary.md)
and the [wire contract](../../../developer-guide/architecture/wire-contract.md).
