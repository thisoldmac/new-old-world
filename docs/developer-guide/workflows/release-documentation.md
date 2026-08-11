---
page_id: dev-workflow-release-documentation
title: Release documentation
description: Final human and automated checks before publishing the alpha documentation.
doc_type: how-to
audience: operator
lifecycle: current
authority: [RELEASING.md, docs/site-integration.yaml, scripts/test-docs]
source_dependencies: [RELEASING.md, docs/site-integration.yaml, docs/assets/screenshots/manifest.yaml, docs/feature-catalog.yaml, scripts/test-docs, scripts/docs-build, .github/workflows/pages.yml, scripts/verify-host-signature, docs/naming.md, contract/resident_version.h, docs/status.md, docs/known-wrong.md, docs/open-issues.md]
media_ids: []
last_verified: 2026-08-11
---
# Release documentation

Start with [the repository release procedure](../../../RELEASING.md). A green
development branch is not a candidate: qualification uses a numbered,
immutable RC tag and records the exact source and artifact identities. The
complete public alpha-bundle assembler named there is still a commissioning
blocker; this checklist does not turn manual assembly into reproducibility.

## Activate the independent documentation site

The selected public target is `https://docs.newoldworldmac.com/`. Documentation
source, validation, build, and deployment remain in this application
repository. A GitHub Pages custom workflow publishes the generated site after
the integrated CI run for a `main` revision succeeds. It checks out that exact
verified revision rather than whichever commit happens to be current when the
deployment begins. The separate `newoldworld-web`
repository owns one stable link to that origin, not the documentation build.

This boundary is deliberate: ordinary documentation corrections must not
rebuild, republish, or create a new revision of the Azure Container App serving
the main website. Do not copy generated HTML between repositories, bake docs
into the website container, or introduce cross-repository commit automation.

The site is rooted at `/` on the documentation subdomain. The maintained
canonical origin, DNS owner, main-site repository, and RFC 9116 expiry live in
`docs/site-integration.yaml`. For a local release-equivalent build, set
`NOW_DOCS_SITE_URL` to the canonical docs URL and run:

```sh
NOW_DOCS_RELEASE=1 scripts/docs-build
```

The release mode refuses incomplete integration, generates `security.txt` and
`robots.txt` from the maintained source, and checks the generated files before
returning success. The Pages artifact includes dot-directories explicitly so
`.well-known/security.txt` is not omitted.

## Review truth and artifacts

- Compare compatibility and limitations with `docs/status.md`, `docs/known-wrong.md`, `docs/open-issues.md`, contract coverage, and MCP coverage.
- Compare every packaged artifact with the active profile in
  `docs/feature-catalog.yaml`; excluded features must not appear in release
  setup instructions or the bundle.
- Freeze an artifact record from the actual packaged output. For every shipped
  payload, record its filename, byte size, and SHA-256. Also record the host's
  verified signing identity, the PowerPC guest's internal Macintosh name,
  creator, and fork sizes, and the Extension's resident version. Do not fill
  this record from a build directory or a planned filename.
- Install the actual host and PowerPC artifacts by the documented path, then
  test the bundled optional Extension both installed and absent. The alpha
  profile excludes the stale NOW-68K artifact.
- Repeat [Connect your first classic Mac](../../user-guide/tutorials/first-connection.md)
  from a clean staging location with no repository checkout, `.env.lab`, or
  source-build directory available. Record every place where the published
  instructions require knowledge or a file that the release bundle does not
  provide.
- Exercise the setup portal from its fixed `/now` route through the final
  mounted image and first named session. Record classic-browser, MacBinary,
  Disk Copy, and hardware evidence separately; do not collapse a host test or
  emulator mount into an end-to-end result.
- If this release intentionally advances the resident release, confirm
  `contract/resident_version.h` and its checked consumers agree. In every
  case, confirm the exact resident build inputs are covered by the required
  shared bake.
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
