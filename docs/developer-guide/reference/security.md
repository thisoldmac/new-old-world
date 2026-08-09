---
page_id: dev-ref-security
title: Security and privacy
description: Network, authorization, data-movement, and vulnerability-reporting boundaries.
doc_type: reference
audience: user
lifecycle: current
authority: [SECURITY.md, contract/asyncapi.yaml]
source_dependencies: [SECURITY.md, contract/asyncapi.yaml, now-host/Sources/Host/GuestListener.swift, docs/site-integration.yaml]
media_ids: []
last_verified: 2026-08-09
---
# Security and privacy

The classic Mac initiates the connection to the host. Treat the configured listener and network as a trusted local environment; do not expose the port directly to an untrusted network. Contract revision checks, guest identity, active-guest selection, bounded frames, and explicit refusals reduce accidental cross-machine actions but are not a substitute for network isolation.

File transfer, screenshots, process data, logs, hardware facts, cloud services, chat, and Mirror can move information off the classic Mac. Each module page identifies its data movement and availability. Optional agent access is constrained by the selected machine's declared tier and the host projection catalog.

The canonical vulnerability-reporting contact is intentionally not invented in this pre-alpha branch. Publication with `NOW_DOCS_RELEASE=1` refuses until `security_contact`, its expiry, and the canonical website origin are set in `docs/site-integration.yaml`; the release build then publishes the matching RFC 9116 `/.well-known/security.txt`.

For current repository policy and private reporting instructions, use `SECURITY.md`.
