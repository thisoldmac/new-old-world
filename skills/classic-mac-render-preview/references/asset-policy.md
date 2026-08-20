# Asset policy

The first version ships no copied system artwork, fonts, screenshots, PICT resources, icons, or sound files. System chrome and glyphs are drawn algorithmically as original planning approximations.

Every declared asset needs one status:

| Status | May influence layout | May be rendered | Meaning |
|---|---:|---:|---|
| `generated-original` | yes | only through a supported component | Created for this preview, with no copied system artwork |
| `bundled-cleared` | yes | only through a supported component | Distributed with explicit usable rights |
| `runtime-system-rendered` | yes | no in the host preview | Drawn by the target OS at runtime, not bundled |
| `local-user-supplied` | yes | only when a supported renderer and local path are present | User-controlled input; do not redistribute automatically |
| `reference-only` | yes | no | Evidence for proportions or behavior only |
| `excluded` | no | no | Known unusable or out of scope |

## Rules

- Reference screenshots may guide measurement but must never be composited into output.
- Extracted Apple resources and system fonts are `reference-only` unless the user supplies a separately documented right to redistribute them.
- Image generation may create application-owned content art, but not system chrome or a purported exact Apple icon/font. Mark it `generated-original` and audit it before use.
- This renderer currently supports generated geometric icon glyphs only. External bitmap compositing is deliberately rejected rather than silently rasterized with unknown palette and rights.
- Record source, rights note, intended use, and redistribution status for every asset.
