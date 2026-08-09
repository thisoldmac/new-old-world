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

<!-- derived-doc v1
sources: contract/asyncapi.yaml now-host/Sources/Host/FrameCodec.swift now-host/Sources/Host/ContractMessages.swift now-guest-ppc/src/core/wire.c now-guest-68k/src/core/wire68.c scripts/docs-source-group tools/docs-gate
sources-sha1: 2c4fd3635ad27196ecf2811921f558859a33c259
derive contract-summary sha256=55e4e7d1518abb241c6ac63a41a4f14740d239569498e3401c5940f6a44205b3 lines=6
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
-->
