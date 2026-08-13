---
page_id: dev-arch-wire-contract
title: Wire contract
description: Framing, connection lifecycle, operations, and change discipline for the shared protocol.
doc_type: reference
audience: developer
lifecycle: current
authority: [contract/asyncapi.yaml]
source_dependencies: [contract/asyncapi.yaml, now-host/Sources/Host/FrameCodec.swift, now-host/Sources/Host/ContractMessages.swift, now-guest-ppc/src/core/wire.c, now-guest-68k/src/core/wire68.c]
media_ids: []
last_verified: 2026-08-09
---
# Wire contract

`contract/asyncapi.yaml` is the normative source for messages, required fields, connection rules, and the command registry. [The generated page](../../generated/asyncapi.md) is a projection for reading; edit the YAML, not the projection.

## Connection sequence

```mermaid
sequenceDiagram
  participant G as Classic Mac guest
  participant H as macOS host
  G->>H: TCP connect
  G->>H: hello (identity, revision, capabilities)
  alt compatible revision
    H-->>G: hello.accept
    loop while connected
      G->>H: ping
      H-->>G: pong
      H->>G: request
      G-->>H: result or refusal
    end
    G-->>H: bye
  else incompatible revision
    H-->>G: hello.refuse
    H--xG: close
  end
```

Text equivalent: the guest dials, identifies itself and its contract revision, and waits for acceptance. Only then may either side exchange application messages. Heartbeats keep the session observable. A graceful side sends `bye`; incompatible revisions are refused before normal traffic.

## Frame and lane rules

An eight-byte header identifies channel, flags, transfer, and payload length. JSON control frames and raw bulk frames are multiplexed. Control words queue and retry; bulk data is recoverable and may be abandoned only at a frame boundary. One transfer owns the bulk lane at a time.

## File transfer

```mermaid
sequenceDiagram
  participant S as Sender
  participant R as Receiver
  S->>R: file.offer or file.request
  R-->>S: accept or refuse
  loop framed bulk data
    S->>R: bulk frame
    R-->>S: file.progress (advisory)
  end
  S->>R: file.end
  R-->>S: receiver result
```

Text equivalent: the initiator proposes one transfer, the receiver accepts or refuses, bulk frames follow, and only receiver-originated progress proves bytes arrived. Completion is receiver-owned; a sender's socket acceptance is not delivery evidence.

## Compatibility rule

Fields are additive unless a revision explicitly changes meaning. Unknown enum values are not consent. Every local `$ref` must resolve, every behavior change begins in the contract, and both receiving directions must retain the same meaning.

## Mirror invalidation

`mirror.invalidate` is an optional symmetric notification, not a command and
not authoritative state. It identifies one session and the newest known
overall and per-domain generations, with quality and loss information. The
receiver coalesces refresh work, repairs `gap` or `unknown` quality, and keeps
cadence polling as the fallback. A hint can make a read happen sooner; only a
coherent reread can publish the new state.

```mermaid
sequenceDiagram
  participant G as Guest state owner
  participant H as Host projection
  G->>H: mirror.invalidate (session, generations, quality)
  H->>H: coalesce and admit refresh
  H->>G: bounded scene and domain reads
  G-->>H: authoritative generation-tagged state
  H->>H: publish only a coherent current set
```

Text equivalent: the guest hints that one or more generations changed; the
host coalesces and schedules bounded reads, receives authoritative tagged
state, and publishes only when the generation set is coherent and current.

<!-- derived-doc v1
sources: contract/asyncapi.yaml now-host/Sources/Host/FrameCodec.swift now-host/Sources/Host/ContractMessages.swift now-guest-ppc/src/core/wire.c now-guest-68k/src/core/wire68.c scripts/docs-source-group tools/docs-gate
sources-sha1: adf6d6f4ae9f11df26971fc3f37dbc6429ccb13a
derive contract-summary sha256=486fe4c5366ae4f3d1cd27b7a9381fcf7b275da681aebcf34ef3130de84fb0cd lines=6
    scripts/docs-source-group contract
rederived: pending
rederived: 2026-08-09T16:22:14-0400 9034e3eb sources, contract-summary 6->6
rederived: 2026-08-09T16:29:42-0400 9034e3eb sources
rederived: 2026-08-09T17:05:28-0400 446cf620 sources
rederived: 2026-08-09T17:08:04-0400 446cf620 sources
rederived: 2026-08-09T17:53:28-0400 ed9436c0 sources
rederived: 2026-08-09T18:53:51-0400 181db7a5 sources
rederived: 2026-08-09T18:56:22-0400 181db7a5 unchanged
rederived: 2026-08-09T19:21:55-0400 dc5bfcd2 sources
rederived: 2026-08-09T19:33:55-0400 c854246d sources
rederived: 2026-08-09T20:56:35-0400 9864da82 sources, contract-summary 6->6
rederived: 2026-08-09T21:05:27-0400 9864da82 sources
rederived: 2026-08-09T21:43:46-0400 2b3c2c0e sources
rederived: 2026-08-09T22:09:30-0400 d54812c2 sources
rederived: 2026-08-09T22:18:48-0400 e637efd3 sources
rederived: 2026-08-10T03:07:04-0400 9cbb4c28 sources, contract-summary 6->6
rederived: 2026-08-10T03:08:46-0400 9cbb4c28 unchanged
rederived: 2026-08-10T03:11:42-0400 9cbb4c28 sources
rederived: 2026-08-10T03:46:36-0400 68d74d72 sources
rederived: 2026-08-10T02:53:59-0400 62603174 sources, contract-summary 6->6
rederived: 2026-08-10T04:18:14-0400 423ef214 sources, contract-summary 6->6
rederived: 2026-08-10T04:49:22-0400 cd585106 sources
rederived: 2026-08-10T04:27:16-0400 886ee556 sources, contract-summary 6->6
rederived: 2026-08-10T04:38:54-0400 886ee556 unchanged
rederived: 2026-08-10T05:38:07-0400 a0ede9ec unchanged
rederived: 2026-08-10T13:37:38-0400 2f62ec11 sources, contract-summary 6->6
rederived: 2026-08-10T13:51:46-0400 f4a92045 sources
rederived: 2026-08-10T14:07:44-0400 b22898ee sources
rederived: 2026-08-10T13:10:56-0400 47bf54fb sources
rederived: 2026-08-10T13:36:45-0400 b15b4827 unchanged
rederived: 2026-08-10T14:49:44-0400 4ea2d97d unchanged
rederived: 2026-08-10T14:20:13-0400 9e432b8b sources
rederived: 2026-08-10T15:11:51-0400 eb9d991c unchanged
rederived: 2026-08-10T15:34:28-0400 72868e9e unchanged
rederived: 2026-08-10T15:52:47-0400 77329146 unchanged
rederived: 2026-08-10T16:52:02-0400 d77cc444 unchanged
rederived: 2026-08-13T16:16:51-0400 a2457b26 sources
rederived: 2026-08-13T17:20:18-0400 6960f962 sources
-->
