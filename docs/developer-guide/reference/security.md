---
page_id: dev-ref-security
title: Security and privacy
description: Network, authorization, data-movement, and vulnerability-reporting boundaries.
doc_type: reference
audience: user
lifecycle: current
authority: [SECURITY.md, contract/asyncapi.yaml]
source_dependencies: [SECURITY.md, contract/asyncapi.yaml, now-host/Sources/Host/GuestListener.swift, now-host/Sources/Host/ConnectionsModuleView.swift, docs/site-integration.yaml]
media_ids: []
last_verified: 2026-08-09
---
# Security and privacy

The classic Mac initiates the connection to the host. Treat the configured listener and network as a trusted local environment; do not expose the port directly to an untrusted network. Contract revision checks, guest identity, active-guest selection, bounded frames, and explicit refusals reduce accidental cross-machine actions but are not a substitute for network isolation.

The Connections page repeats that boundary beside the listener controls. The
listener is intentionally reachable through the host's LAN interfaces; a host
test dials it through a non-loopback routable address so a loopback-only change
cannot masquerade as compatible hardening.

File transfer, screenshots, process data, logs, hardware facts, cloud services, chat, and Mirror can move information off the classic Mac. Each module page identifies its data movement and availability. Optional agent access is constrained by the selected machine's declared tier and the host projection catalog.

The selected public vulnerability-reporting contact is
`github@shelbel.net`; GitHub private vulnerability reporting remains the
preferred route when the repository provides it. Publication with
`NOW_DOCS_RELEASE=1` still refuses until the contact's future RFC 9116 expiry,
the exact website repository, and the canonical website origin are set in
`docs/site-integration.yaml`; the release build then publishes the matching
`/.well-known/security.txt`.

For current repository policy and private reporting instructions, use `SECURITY.md`.
