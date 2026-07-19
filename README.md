# New Old World ("NOW")

New Old World is a clean, independently versioned prototype for joining a
classic Mac and a modern Mac around one human-facing task: taking and managing
screenshots. Display names, creator codes, bundle identifiers, and preference
keys live in the two `ProductIdentity` files so naming changes do not leak
across the codebase.

## First slice

- `guest/` is a PowerPC Carbon application for Mac OS 9.1–9.2.2. Its Capture
  button snapshots its own window content at 1, 8, 16, or 32 bits using
  QuickDraw, then keeps a bounded in-memory history that can be browsed.
- `host/` is a native macOS menu-bar and window application. It has a small
  module registry and a polished Screenshots module, but deliberately reports
  that no Mac is connected until the single host/guest transport is built.
- Build products stay outside the repository. The host bundling script rejects
  destinations inside this checkout.

Mac OS 8.6 with CarbonLib 1.3 may work, but it is compatibility territory, not
the supported target. Global shortcuts, other-process capture, persistence of
guest image history, and transport are deliberately deferred.

## Build

Guest, with Retro68:

```sh
cmake -S guest -B /private/tmp/now-guest-ppc -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/path/to/Retro68/toolchain/powerpc-apple-macos/cmake/retrocarbon.toolchain.cmake
cmake --build /private/tmp/now-guest-ppc
```

Host tests and app bundle:

```sh
swift test --package-path host --scratch-path /private/tmp/now-host-tests
./scripts/build-host-app /private/tmp/now-host-product
open /private/tmp/now-host-product/New\ Old\ World.app
```

See [docs/architecture.md](docs/architecture.md) for the seams this slice keeps
open without implementing speculative infrastructure.

