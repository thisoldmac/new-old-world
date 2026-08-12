<!-- now-doc-provenance: generated reviewed=false -->

## Change

Domain: `contract | host | guest-ppc | guest-68k | resident | docs | tooling | release | cross-cutting`

What changed, and why does it belong in this domain?

- [ ] Branch name is creator-neutral `<type>/<kebab-slug>`, or this branch
      predates the policy boundary.
- [ ] PR title is `type(scope): concise outcome`; scope is optional.

## Contract and symmetry

- [ ] No wire or resident-memory behavior changed.
- [ ] The authority contract changed first, and every sender/receiver was updated.
- [ ] Guest console/wire parity and served/proven documentation remain current.

## Verification

- [ ] I watched each new guard fail against the mutation it claims to catch.
- [ ] `scripts/test-all` passed, or every skipped/unavailable stage is named below.
- [ ] The result is labelled builds, tested, emulator-verified, or metal-verified.

Skipped or unavailable proof:

## Public-release hygiene

- [ ] No private addresses, credentials, machine paths, licensed assets, or session scratch entered the tree.
- [ ] User-visible behavior and `docs/open-issues.md` are current.
- [ ] Security, privacy, provenance, and release-profile effects are stated.
