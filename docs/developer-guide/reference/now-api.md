---
page_id: dev-ref-now-api
title: NOW API v1
description: Public HTTP contract, authentication, compatibility, errors, events, and transfer lifecycle for local applications.
doc_type: reference
audience: developer
lifecycle: current
authority: [contract/now-api.openapi.json]
source_dependencies: [contract/now-api.openapi.json, now-host/Sources/Host/API, now-host/Sources/Host/MCP/HTTPMCPTransport.swift, now-host/Sources/Host/MCP/MCPTransportPreferences.swift]
media_ids: []
last_verified: 2026-08-20
---

<!-- now-doc-provenance: generated reviewed=false -->

# NOW API v1

NOW API v1 is the public application interface for the macOS host. It is an
ordinary JSON HTTP API at `http://127.0.0.1:19870/api/v1` by default. An
application does not initialize MCP, list tools, or use the private local
adapter protocol.

The authoritative OpenAPI 3.1 document is
`contract/now-api.openapi.json`.
`GET /api/v1` returns the running host's API major, schema revision, contract
digest, operation link, and request limits. Compare those values with the
contract your application was built against before issuing a mutation.

## Network and authentication

V1 listens on loopback only. It has no LAN mode, TLS termination, daemon, or
remote security posture. A local reverse proxy does not turn that absence into
a supported remote deployment.

Every request carries the host-issued secret as:

```http
X-API-Key: <secret>
```

API v1 has one application key and no scopes. It does not accept a bearer
header or an MCP OAuth access token. The sibling `/mcp` route retains its own
none, bearer, and OAuth modes; those modes do not change `/api/v1`.

The host currently exposes the shared secret through **Copy Bearer Token** on
the MCP HTTP card when bearer mode is selected. The official CLI can also read
the same private mode-0600 application credential automatically. A dedicated
application-facing copy/bootstrap control is not yet present; third-party
applications should not discover or parse the private credential file.

## Resource model

Use `guest` for a connected or remembered classic Mac. A stable guest ID and
an exact live guest session ID are deliberately different:

- reads may address a stable guest;
- unsafe guest operations require `X-NOW-Guest-Session` with the exact current
  session;
- `DELETE /connections/{sessionID}` disconnects one session, not a remembered
  guest;
- the host can start or stop accepting inbound connections, but cannot dial a
  guest.

The first-class route families cover identity and operations, guests,
listener state, exact connections, console commands, files, transfers, and
events. `GET /api/v1/operations` publishes the admitted neutral operation
catalog. `POST /api/v1/operations/{operationID}` reaches only operations
declared public; agent-only conveniences and MCP compositions are excluded.

## Results and errors

Operation results carry a transport-neutral `disposition`: `completed`,
`refused`, `unavailable`, `failed`, or `cancelled`. The common first-class
`OperationResult` carries `value` only for `completed` and otherwise carries a
stable error `code`, safe `message`, and `reach`. `GenericOperationResult`
intentionally preserves the typed domain payload under `value` for completed,
refused, unavailable, and failed projection outcomes, and may carry the
neutral error beside it. In both forms, use the outer disposition; do not
infer success by searching fields nested inside the domain payload.

HTTP failures use an error envelope with a request ID and the same stable
error shape. Keep the request ID for support. Treat the HTTP status as the
transport outcome and the disposition as the product outcome. Clients should
ignore unknown optional fields, but must refuse unknown dispositions and API
majors.

## Compatibility

The route and OpenAPI `info.version` identify public API v1. The projection
catalog version, MCP catalog digest, private local protocol, and host build are
separate identities.

Within v1, new optional fields, operations, and event types may appear.
Required-field meaning and disposition semantics do not change. Removing an
operation, narrowing accepted input, or changing a required field requires a
new major or an explicit compatibility bridge. The contract digest identifies
the exact OpenAPI document; it is not a promise that two host builds behave
identically.

## Events

`GET /api/v1/events` requires `Accept: text/event-stream`. It is a bounded,
live-only Server-Sent Events stream. Events are coarse refetch hints, not an
event-sourced state model. The server retains no replay log and rejects
`Last-Event-ID` or cursor requests.

On `stream.ready`, `stream.resync-required`, or every reconnect, refetch the
resources named by `refetch`. Unknown future event types are safe to ignore
only after performing the same refetch behavior. Heartbeat comments carry no
state.

## Transfer lifecycle

Uploads are application-chunked, not HTTP chunked-transfer encoded:

1. `POST /guests/{guestID}/transfers/uploads` declares destination, byte
   length, SHA-256, and `data` or `macbinary` container.
2. Send sequential raw `PUT /transfers/{id}/content?offset=N` requests of at
   most 8 KiB each.
3. `POST /transfers/{id}/commit` verifies length and digest, then uses the
   existing single guest transfer lane.
4. Read the transfer resource until it reaches a terminal state, or cancel it
   with `DELETE /transfers/{id}`.

One file is limited to 32 MiB. An uncommitted private stage expires after ten
minutes and is deleted before the transfer is reported expired. Offsets,
digest, exact guest session, and the one-lane rule are enforced.

Downloads begin with `POST /guests/{guestID}/transfers/downloads`. Once the
returned resource says content is available, stream
`GET /transfers/{id}/content`; the host sends bounded file-backed chunks rather
than materializing the whole file in one response buffer.

## Minimal independent client

`fixtures/now-api-client.py` is a standard-library smoke client that validates
the API-key header and required paths against OpenAPI, derives the server base
path, then calls identity and guest discovery. It contains no MCP or
private-host vocabulary and is exercised from a copied clean source tree by
the distribution gate.
