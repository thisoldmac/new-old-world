@AGENTS.md

## Claude Code

- Add only Claude-specific notes here; the shared conventions live in
  AGENTS.md.
- **Guest work requires the classic-Mac skills.** Load
  `classic-mac-toolbox-platform` before touching `guest/app` (PPC/CFM
  application, Retro68, Mixed Mode, Toolbox managers) and
  `classic-mac-init-platform` before touching `guest/extension` (68K
  `INIT`, system-heap residency, trap and `GNEFilter` hooks). Do not guess
  an API floor — check it.
- Lab instruments (emulator, `tools/launch`/`hc`/`push`, `classicfmt`,
  `mcp-classic`) live in the parent TimBotTu checkout at `..`. They drive
  tests and deploys only; nothing from there ships
  (AGENTS.md > "TimBotTu is the lab, not a dependency").
- Emulator smokes run from the parent checkout: `tools/launch` boots a
  session-private clone; stop via QMP `quit`, never `pkill`. Launch your
  own VM rather than borrowing a running one.
- **You cannot screenshot the host app's window** — driving Michelle's
  desktop is off-limits. Verify the host through the data pipeline
  (wire→scene logs, fixture tests) and the app's own offscreen
  render-screenshot. Platinum fidelity is a human judgment.
- Two reminders that have bitten before, both in `docs/CONTROL-SURFACE.md`:
  the `key` verb wants **integers** on the raw wire (mods are
  `evtQModifiers` bits, and menu shortcuts match on **keycode**, not
  character), and guest JSON carries raw MacRoman bytes that are invalid
  UTF-8 — repair-decode before parsing or `JSONSerialization` refuses.
