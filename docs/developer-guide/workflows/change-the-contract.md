---
page_id: dev-workflow-change-contract
title: Change the contract
description: Safely change a message, command, or connection rule shared by host and guests.
doc_type: how-to
audience: developer
lifecycle: current
authority: [contract/asyncapi.yaml, AGENTS.md]
source_dependencies: [contract/asyncapi.yaml, tools/docs-contract-projector, now-host/Sources/Host/ContractMessages.swift, now-guest-ppc/src/core/wire.c, now-guest-68k/src/core/wire68.c]
media_ids: []
last_verified: 2026-08-09
---
# Change the contract

## Update the authority first

Edit `contract/asyncapi.yaml`. Register new component messages in the channel map, resolve every local `$ref`, state required fields once, and preserve symmetric meaning. For additive changes, describe the behavior of an older receiver.

## Implement both receiving sides

Update the host decoder/model and each guest that serves the operation. If a guest deliberately lacks the capability, record that posture in `docs/contract-coverage.md`; do not leave the other direction implicit.

## Regenerate the readable projection

```sh
scripts/docs-contract
```

The generated Markdown contains operations, messages, and `x-commands`. The documentation gate compares it byte-for-byte with a fresh projection.

## Test the seam

Add fixtures that originate independently of the decoder under test. Run `scripts/test-native`, the host conformance suites, `scripts/test-docs`, and finally `scripts/test-all`. If the message is assembled across several C writes, add the explicit conformance fixture requested by the failing test.
