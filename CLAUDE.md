@AGENTS.md

## Claude Code

- Add only Claude-specific notes here; the shared conventions live in
  AGENTS.md, and the guest UI errata in docs/guest-ui-start-here.md.
- Load the `classic-mac-carbon-ui` skill before any guest UI work, and
  run its `audit_source.py` over `now-guest-ppc/src/**/*.c` afterwards.
- A new guest feature is a Workshop **module**, never a new window:
  docs/adding-a-workshop-module.md.
