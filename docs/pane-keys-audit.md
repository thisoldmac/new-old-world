# Pane keystrokes → guest front app (audit lane, in progress)

Lane owner: audit/pane-keys. Status: investigating before editing.

Starting facts, gathered from the guest source and the existing docs
before writing anything:

- `now-guest-ppc/src/input/input_cmds.c` (`now_input_run_key`) already
  implements the wire's `key` verb: `PostEvent(keyDown, ...)` then
  `PostEvent(keyUp, ...)`, keyDown's `OSErr` load-bearing, keyUp's
  `evtNotEnb` reported as a row and never treated as failure, and `mods`
  refused with anything but 0 (`now_key_check`, `input_args.c:158-159`).
  Matches every upstream fact in the brief for the guest half.
- The wire's parameter name is `mods` (`contract/asyncapi.yaml:3079`,
  `input_cmds.c:227`) — the upstream `{key, modifiers}` naming bug does
  not exist here.
- **No host-side pane keystroke path exists yet.** `docs/open-issues.md`
  ("`key`, `type` and `click` are unavailable by design (2026-08-01)")
  and `docs/mcp-coverage.md` (`key` row, marked **W3, planned**) both
  already record this: `ActionModel.availability(.key)` answers
  `.unavailable`, and there is no `KeyProjection.swift` / equivalent in
  `now-host/Sources/NOWAgentIntegration/Projection/`.
- Continuing to build the host projection + pane keyDown capture next.
