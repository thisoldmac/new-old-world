---
page_id: dev-workflow-release-documentation
title: Release documentation
description: Final human and automated checks before publishing the pre-alpha documentation.
doc_type: how-to
audience: operator
lifecycle: current
authority: [docs/site-integration.yaml, scripts/test-docs]
source_dependencies: [docs/site-integration.yaml, docs/assets/screenshots/manifest.yaml, docs/feature-catalog.yaml, scripts/test-docs, scripts/docs-build, docs/status.md, docs/known-wrong.md, docs/open-issues.md]
media_ids: []
last_verified: 2026-08-09
---
# Release documentation

## Complete the deferred website handoff

The intended public route is `/app/docs/` in the separate
`newoldworld-web` repository, but that integration is deliberately deferred
until the website is published. Until then, keep using the standalone
`/docs/` local preview and do not treat a normal docs build as a deployable
website handoff.

When the handoff is implemented, keep docs source and validation here, publish
an immutable docs artifact from an app release, and have the website repository
pin and assemble that artifact under `/app/docs/`. Do not copy generated HTML
between working trees or make the app repository own the website deployment.

Then set the canonical origin, security contact, future RFC 9116 expiry, and
final base-path contract in `docs/site-integration.yaml`. Set
`NOW_DOCS_SITE_URL` to the canonical docs URL and run:

```sh
NOW_DOCS_RELEASE=1 scripts/docs-build
```

The release mode refuses incomplete integration and generates `security.txt` and `robots.txt` from the maintained source.

## Review truth and artifacts

- Compare compatibility and limitations with `docs/status.md`, `docs/known-wrong.md`, `docs/open-issues.md`, contract coverage, and MCP coverage.
- Compare every packaged artifact with the active profile in
  `docs/feature-catalog.yaml`; excluded features must not appear in release
  setup instructions or the bundle.
- Install the actual host and PowerPC artifacts by the documented path, then
  test the optional extension both installed and absent. The initial profile
  excludes the stale NOW-68K artifact.
- Do not close a screenshot gap for a placeholder. List all remaining placeholder IDs in the release notes.
- Confirm no page describes tested or emulator evidence as metal-verified.

## Perform the manual accessibility review

Automated checks are a floor, not certification. Record a human result for:

- keyboard-only navigation, including visible focus and the skip link;
- browser zoom at 200% and 400%;
- reflow at 320 CSS pixels without lost content or two-dimensional page scrolling;
- VoiceOver spot checks on the docs home, tutorial, how-to, module reference, table, diagram, and screenshot placeholder;
- light and dark contrast, reduced motion, and diagram text equivalents.

## Prove the landing control

Make the CI check named `Documentation` required in the remote `main` ruleset, then open a deliberately failing documentation change and prove it cannot merge. A green workflow that is not required is not a landing gate.
