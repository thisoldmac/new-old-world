# Mirror — a live semantic mirror of a classic Mac desktop

Mirror renders and drives a **Mac OS 9.1 PowerPC** machine's real user
interface from **semantic state, not pixels**: actual windows, controls,
and menus travel the wire as structure, and a native macOS app draws them
in Platinum and sends input back. A screenshot shows you what the screen
looked like; Mirror hands you the thing the screen *was*.

Timbuktu was the inspiration, not the blueprint — there is no QuickDraw
bottleneck INIT here. We render the meaning the guest already emits.

## Target

**PowerPC, Mac OS 9.1, validated on `mac99`.** One target, on purpose:
the emulator is the iteration bench and the correctness gate, and a single
ISA keeps the guest app's Open Transport path free of the 68K ASLM
blocker. Real hardware follows once the emulator gate is honest — and
anything emulator-only (QMP-driven drag, closed-loop mouse positioning) is
**typed** emulator-only in the action model and degrades honestly
elsewhere. No load-bearing emulator-only mechanisms.

The one exception to "PPC": **the extension is 68K.** An `INIT` is 68K
code even on a PowerPC machine, so `guest/extension` builds with the
Retro68 68K toolchain while `guest/app` builds PPC/CFM. That is a
property of classic Mac OS, not a compromise.

## The three pieces

| Piece | Path | What it is |
|---|---|---|
| **Extensions** | `guest/extensions` | Two resident 68K `INIT`s. **AXPeek** — Publishes each application's `CurrentA5`/`WindowList`/`MenuList` roots via `Gestalt('TBax')`. Solves the A5-world barrier: per-process Toolbox roots are invisible from another process. Observes only; never actuates, never dereferences a foreign tree. |
| **Guest app** | `guest/app` | The PPC agent. Maps an AXPeek sample to the live Process Manager partition, walks *only* those validated regions, and serves the scene and action verbs over JSON/TCP on Open Transport. |
| **Host app** | `host/MirrorKit` | Swift. `MirrorKit` = the headless semantic core (scene IR, hit-testing, action model). `MirrorKitUI` = the Platinum renderer. `MirrorApp` = the window, the CLI, and `--serve`. |

The seam is deliberate and one-directional: **the renderer never sees the
wire.** `WireClient` is the only wire-touching code in the host, and every
rendered element carries its `ref` and `rect`, so hit-testing and action
dispatch live in the headless core where they are testable without a
window.

## Layout

| Path | Role |
|---|---|
| `guest/extensions/axpeek/` | AXPeek `INIT` (68K) — the address oracle |
| `guest/extensions/qdpeek/` | QDPeek `INIT` (68K) — the QuickDraw op stream |
| `guest/app/` | Mirror agent (PPC/CFM Retro68) — walk + serve |
| `host/MirrorKit/` | SwiftPM package: core, UI, `MirrorApp` |
| `host/MirrorKit/Tests/MirrorKitTests/Fixtures/` | The captured scene corpus — regression tests during maturation, the contract gate at IR v1 |
| `docs/` | Plan, control surface, asset contract, teardown notes |
| `tools/` | Emulator rig: stage, spin up, tear down; asset extraction |
| `tests/` | Protocol and end-to-end drivers |
| `assets/` | The extracted Platinum pack |

## Test drive

```bash
MIRROR_DISPLAY=1 tools/spin-up.sh
```

Boots a throwaway mac99 clone, deploys both guest pieces, and opens the
mirror window beside the real guest screen. See
[docs/TEST-DRIVE.md](docs/TEST-DRIVE.md) — including the one thing not to
do (`axdo` wedges the session) and what the act plane can and cannot do
yet ([docs/STATUS.md](docs/STATUS.md)).

## Build

Host:

```bash
swift build --package-path host/MirrorKit
```

Guest app (PPC) and extension (68K) — see `guest/app/README.md` and
`guest/extensions/axpeek/README.md` for the toolchain paths and the staging
recipe. Both deploy onto a **session-private emulator clone**, never a
shared base image.

## Where this came from

Mirror was extracted from the TimBotTu lab on 2026-07-29, carrying its
history (`prototypes/mirror` and `axpeek`, 75 commits). The plan that
shaped it — human-first maturation, the scene IR unstable until a gated
parity phase, render-screenshot rather than host capture — is
[docs/MIRRORKIT-PLAN.md](docs/MIRRORKIT-PLAN.md). The prototype's own
notes, including the asset-pack contract and the measured wire-stress
numbers, are [docs/PROTOTYPE-NOTES.md](docs/PROTOTYPE-NOTES.md).

The lab's copy is frozen, not deleted: TimBotTu still builds the
pre-extraction `MirrorKit` for its workshop and its `service.mirror`
managed service. Those two trees diverge on purpose — see
[AGENTS.md](AGENTS.md) > "TimBotTu is the lab, not a dependency."
