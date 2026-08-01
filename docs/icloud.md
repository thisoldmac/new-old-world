# iCloud — the module, both halves

"Making Old World Macs a first-class member of the modern Apple
ecosystem — or at least giving them a travel visa." This page is the
visa office. The host chooses what of this Mac's iCloud to serve; the
classic Mac browses it, one service at a time, each rendered the way
that service deserves. The classic machine never authenticates to
anything: the host holds the credentials, speaks the modern protocols,
and the wire carries pre-digested, era-appropriate rows.

The wire family is `cloud.*` (contract `guestAsksCloud` /
`hostServesCloud`, registry in `x-cloud`). It runs one direction by
definition — its subject is the host's own iCloud, which no classic
Mac has — so unlike the file family there is no symmetric half waiting
to be built. Additive, no revision bump: discovery is a guest sending
`cloud.services` and reading the report, and silence past its deadline
means a host that predates the family — a status line, not an error.

## The services

The registry (`now-host/Sources/Host/CloudServices.swift`) serves
three today; a service that is off or unauthorized still reports
itself with why, so the guest's dropdown can say "Photos — turn on at
the host" instead of not mentioning Photos.

- **Drive** is deliberately NOT a second browser. Its transport is the
  file family against the host's share — which already lists iCloud
  placeholders logically and materializes on demand
  ([files.md](files.md)) — so the drive service only reports whether
  the share IS iCloud Drive, and `cloud.list` for it answers
  `not-listable` naming the Files page. One implementation, two
  renderers, the rule this repo keeps paying to relearn.
- **Photos**: newest first, pages of title/date rows; `cloud.detail`
  is a card of what the library knows; `cloud.get` delivers ONE photo
  as an ordinary `file.offer` into the guest's share — JPEG whatever
  modern container the library holds, typed `JPEG`/`ogle` so it opens
  by double-click. An original iCloud has not materialized starts its
  download and refuses `busy`, the same bargain the share strikes for
  Drive placeholders.
- **Contacts**: alphabetical, the card is the deliverable —
  phones/emails/addresses as [label, value] rows in the person's own
  labels. `cloud.get` is refused until the classic side can read a
  vCard.

Every human-readable string is converted before sending (composed,
MacRoman-expressible): the host is the only side that can spell both
alphabets — the same reason text conversion is the host's job in the
file family.

## The host page

The iCloud module (sidebar, after Files) is the person-facing face of
the same registry: one row per service, the exact report a guest gets,
plus the switches. Photos and Contacts default **off**
(`cloud.photos.enabled` / `cloud.contacts.enabled`); turning one on
surfaces macOS's own consent prompt (the Info.plist usage strings say
what the wire will do with the grant). Drive's switch is the share
itself — the page's button is the same act as picking iCloud Drive in
the Files footer.

Serving is ungated past the handshake, like the share (decided
2026-08-01): the switches are the consent, per service.

## The guest page

Planned as one Workshop module with a service dropdown and a
per-service render — list+save for Photos, list+card for Contacts, a
pointer to Files for Drive. Not yet built; when it lands, this section
gets rewritten from what actually shipped, and the guest's emitted
`cloud.*` messages get fixtures in `GuestWireFixtureTests`.

## What is and is not proven

Wire serving is **tested** (`CloudServingTests`, fake providers over a
loopback wire; refusal-code mutation watched failing). The real
providers are thin and deliberately untested here: Photos and Contacts
cannot be exercised without this Mac's TCC grants, and what only a
signed-in, access-granted machine can prove is ledgered in
[open-issues.md](open-issues.md). Nothing in this family is
metal-verified yet.
