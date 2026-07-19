# Architecture

## Product boundary

The repository owns two applications and, eventually, exactly one connection
between them. It does not import TimBotTu runtime packages or expose a general
remote-control surface.

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

The placeholder is not a product decision. Rename these two files first:

- `guest/src/product_identity.h`
- `host/Sources/Host/ProductIdentity.swift`

Build target and directory names are intentionally generic (`guest`, `Host`).

