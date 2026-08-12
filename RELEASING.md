<!-- now-doc-provenance: generated reviewed=false -->

# Releasing New Old World

New Old World uses release candidates. A green development branch is not a
release, and a build copied from an untagged checkout is not a release
candidate.

## Branches

- `main` is the protected, candidate-ready integration branch. It accepts pull
  requests only and should always satisfy the repository gates.
- Working branches are creator-neutral `<type>/<kebab-slug>` names. Types are
  `feat`, `fix`, `docs`, `refactor`, `test`, `build`, `ci`, `chore`, `perf`,
  and `revert`. Contributor and automation names are not prefixes. Technical
  domain remains pull-request metadata and may be an optional Conventional
  Commit scope: `feat(guest-ppc): add bounded transfer resume`.
- The policy transition grandfathers a nonconforming branch only when its
  merge base predates `tools/git-policy`. Rebasing or creating work after that
  boundary adopts the current grammar. Dependabot is an explicit
  service-managed exception.
- `release/vX.Y.Z` is cut from a green `main` for qualification. After the cut,
  it accepts only reviewed fixes, release metadata, documentation, and
  packaging changes. Product work continues on `main`; a release fix is also
  merged forward when it applies there.

GitHub `main` is protected by the active **Protected main** ruleset recorded in
`.github/repository-policy.json`: direct, force and deletion pushes are
blocked; changes require a linear squash or rebase pull request, resolved
review conversations, and **Git policy**, **Documentation**, **Native guest
tests**, **Host suites and app builds**, and **No lab configuration in the
tree**. Zero approvals are required while this is a solo-maintainer repository.
Branches do not have to rerun against every intervening main commit yet; that
deliberately avoids spending another macOS runner cycle when concurrency is
low. Run `tools/github-policy-check` to detect drift instead of trusting this
prose.

Before the first `release/v*` branch is cut, give that pattern an equivalent
ruleset. It is intentionally not created speculatively while no release branch
exists. Required signing also remains deferred until human, agent and
GitHub-generated commits all have a verified signing path.

## Candidate and final identities

The application family version and lifecycle live in
`contract/product_version.h`. Numeric version, maturity, and candidate
iteration are separate identities: the current example is numeric `0.2.0`,
lifecycle `prealpha.1`, and a candidate iteration such as `rc.3`. The rendered
product identity is `0.2.0-prealpha.1`; the candidate appends `-rc.3` without
changing the product bytes. The
independently deployable Extension version lives in
`contract/resident_version.h`. Change a version once, then run
`tools/product-version-gate check` and the Extension bake gates rather than
editing generated copies independently.

Candidate tags are annotated and immutable:

```text
now-product-vX.Y.Z-STAGE.M-rc.N
now-extension-vX.Y-rc.N
```

Final tags remove the candidate suffix:

```text
now-product-vX.Y.Z-STAGE.M
now-extension-vX.Y
```

`STAGE.M` is `prealpha.N`, `alpha.N`, or `beta.N`. A lifecycle of
`release.0` omits the stage suffix. Classic Finder metadata maps pre-alpha to
NumVersion `development`, then uses the native alpha, beta, and release stages.
The product-version gate rejects unknown stages, invalid sequence numbers,
stale host or classic copies, and lifecycle rollback at the same numeric
version. RC numbering remains independent: any changed source, metadata, or
artifact requires a new RC number.

Each annotation must contain the exact component, deterministic build identity,
and artifact digest:

```text
NOW-Component: application
NOW-Build: <64 lowercase hex characters>
NOW-SHA256: <64 lowercase hex characters>
```

Use `NOW_UPDATE_CHANNEL=candidate` and `NOW_RELEASE_CANDIDATE=N` when
configuring the PPC or Extension CMake build. The generated update sidecar
records `channel: candidate`, the candidate number, the annotated tag, and its
source revision. `tools/write-update-manifest.py` refuses an unnumbered
candidate, a lightweight or moved tag, a dirty tracked tree, a tag on another
revision, or an annotation that does not pin the bytes. Final publication uses
`NOW_UPDATE_CHANNEL=release` and the final annotated tag.

Never replace a candidate tag. If any source, build input, documentation, or
artifact byte changes, increment `N` and qualify a new candidate. Promote the
exact accepted candidate revision to final tags; if that revision must change,
it needs another candidate first.

## Qualification

For every candidate:

1. Rebase or merge the current `main`, resolve derived documents and receipts
   deliberately, and leave the tracked tree clean.
2. Run `scripts/test-all` with Retro68 available. Record every skip; green is
   **tested**, not metal-verified.
3. Run the applicable emulator and physical-hardware gates. Record missing
   metal proof in the release notes and `docs/open-issues.md`; do not silently
   promote “tested” to “works on hardware.”
4. If resident inputs changed, produce the exact shared bake receipt required
   by the main/ref gate and verify the staged image.
5. Build candidate-channel artifacts from the tagged revision. Verify classic
   file identities and generated sidecars, then compute release checksums. Run
   `NOW_HOST_SIGNING=release scripts/test-host`; the ordinary unsigned CI build
   is not evidence that the candidate carries the owner release identity.
6. Check the active feature profile, current limitations, security boundary,
   licenses, and artifact provenance against the actual bundle.
7. Publish the `-rc.N` GitHub release as a prerelease. Final publication reuses
   the accepted revision and marks the final product tag as the release.

The planned alpha profile is for a trusted local network. Its classic wire is
plaintext, unauthenticated, and intentionally reachable beyond loopback; do
not describe a candidate as safe for an untrusted LAN or the internet. See
`SECURITY.md`.

## Current commissioning blockers

The GitHub owner, website repository, documentation-host architecture, and
vulnerability-reporting contact are selected in `docs/site-integration.yaml`.
Before the first public GitHub release, activate the documentation site, set
its canonical origin and a future RFC 9116 expiry, then run
`NOW_DOCS_RELEASE=1 scripts/test-docs`. This repository also still needs one
reproducible command that assembles the complete public alpha bundle and
checksum inventory. Do not substitute a hand-built folder while calling the
process reproducible.
