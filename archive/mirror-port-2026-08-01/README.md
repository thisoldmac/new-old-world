# The Mirror port that was thrown away (2026-07-31 → 2026-08-01)

**Status: archived. Not built, not referenced by anything.** Kept only so
its measurements and its guest-side pieces can be read later.
(`README-of-the-port.md` beside this file is the repo README as it stood
inside that work, carried along unchanged.)

## What this was

Two days of re-implementing Mirror's capability *inside* NOW: MirrorKit /
MirrorKitUI vendored into `now-host`, a Mirror module page, an act plane
(`winact` / `ctlact` / `menuact` / `key`) served through NOW's own
extension, a content plane (`qdtrace`), a pixel producer
(`capture.region`), scene emission for desktop and folder items, an act
pump (`now-pump/`), and MCP tools (`now_scene`, `now_find_elements`,
`now_wait_for`, `now_key_act`).

Full history: branch `claude/mirror-parity-overnight` (65+ commits).

## Why it was thrown away

**It did not drive the guest from the pane.** Menu bar mostly empty, menus
that dropped down but did nothing, no launching, no clicking, no move or
resize — on a build whose gate was green.

The reason the gate was green while the product was not: every acceptance
number in this work was measured by **probe scripts against the wire
verbs**, never through the pane. "`winact` closed a window 10/10" and "a
person can close a window in the mirror" are different claims, and only
the first was ever tested. The path a person actually uses was never
verified end to end by anyone, and the reports read as though it had been.

Mirror had already solved all of this, working, on the same OS and the
same emulator. Re-deriving it inside NOW produced a worse copy at very
large cost in time and tokens.

## What replaced it

`now/mirror/` — the Mirror project vendored whole, keeping its own wire,
its own INITs and its own MCP surface. NOW's Mirror module launches
Mirror's guest and host apps rather than reimplementing them.

## What may still be worth reading here

- `now-guest-ppc/src/scene/scene_desktop.c` — Desktop Folder walk via
  `fdLocation`; volumes via an indexed `PBHGetVInfo` walk.
- `now-guest-ppc/src/content/` and `ext/src/now_content.c` — the qdtrace
  ring, including the fix that per-record tick stamps were never taken in
  record mode (`content_stamp()` ran only on the count-mode branch).
- `now-pump/` — a faceless 68K background application that posts clicks
  from a classic context, because a Carbon application cannot:
  `PPostEvent` is `CALL_NOT_IN_CARBON`, and a background Carbon app's
  `WaitNextEvent` never falls through to the classic Event Manager.
- `tools/stage-ext.py` — staging verified by fork size read back off the
  guest; note that a 68K application's code lives in the RESOURCE fork, so
  `data=0` is correct and a `min_data` assertion rejects a good build.
- `docs/mirror-parity-ledger.md` and `docs/open-issues.md` — the
  measurements, including which of them were wire-only.

## The lesson

A capability is not shipped when its verb answers on the wire. It is
shipped when a person can do the thing in the product. Measure there, and
say plainly which of the two a number describes.
