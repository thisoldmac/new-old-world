# Architecture

## Product boundary

The repository owns two applications and, eventually, exactly one connection
between them: a single versioned contract over one multiplexed wire. It does
not import TimBotTu runtime packages or expose a general remote-control
surface. The stack stays concise, human-facing, and polished — one app on each
side, nothing else.

The product envelope is **PowerPC only** (decided 2026-07-19): the guest is a
Carbon app and takes full advantage of the 8.6+ toolbox (CarbonLib, Open
Transport, Appearance). A 68K build/port/sibling may exist someday; it is
explicitly out of scope and must not constrain this codebase.

## Wire contract

[contract/asyncapi.yaml](../contract/asyncapi.yaml) is the contract: an 8-byte
binary frame header multiplexing a JSON control channel and a raw bulk channel
over one TCP connection, defined as AsyncAPI 3.0 with JSON Schema payloads.
The frame header and connection rules are normative prose at the top of that
file; the revision (`x-contract-revision`) is a single integer, and unequal
revisions refuse cleanly with a reason the UI shows.

The **guest dials the host**. Classic Mac OS listeners are the historically
fragile half of OS 9 networking (leaked disconnect indications, accept races,
silent holders); dialing out keeps every listener on the modern side, where
they are boring. The host address is user-entered on the guest for now;
discovery can come later without touching the contract.

```text
Mac OS 9 guest app  <---- one future protocol ---->  macOS host app
  capture target                                      module registry
  capture engine                                      screenshots module
  bounded history                                     menu bar + window
```

The first executable slice ends before the protocol. The guest is useful on its
own; the host presents an honest disconnected state. This lets the capture
model and human interface settle before network choices harden into a public
contract.

## Guest ownership

- `capture` converts one explicitly supplied window into an offscreen GWorld.
  It knows nothing about buttons, history, files, or networking.
- `capture_store` owns bounded session history and disposes GWorlds.
- `main` owns the Toolbox event loop and draws the current capture.

The target is a `WindowRef` rather than an implicit screen. Today `main` passes
its own window. A future app/window picker can supply another authorized target
without changing history or rendering.

## Host ownership

- `ModuleRegistry` is the composition root. Modules are data descriptors rather
  than singletons with hidden lifecycle.
- `HostAppState` owns selection and persistence.
- `ScreenshotsModuleView` owns screenshot-specific controls and empty/history
  presentation.
- `AppDelegate` owns AppKit lifecycle, status item, and the persistent window.

The host model already names supported capture depths, connection state, and
capture records. No mock transport or fake screenshot data is shipped.

## Naming seam

The product is "New Old World" — "NOW" for short (decided 2026-07-19). Display
names, creator codes, bundle identifiers, and preference keys stay confined to
two files so any future naming change cannot leak across the codebase:

- `guest/src/product_identity.h`
- `host/Sources/Host/ProductIdentity.swift`

Build target and directory names are intentionally generic (`guest`, `Host`).

