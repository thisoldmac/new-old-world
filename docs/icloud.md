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

One Workshop module (`now-guest-ppc/src/cloud/`), the eleventh page:
a service dropdown rebuilt from each `cloud.report`, a two-column Data
Browser for the chosen service's rows (paged straight through, the
Files browser's rule), a card pane for the selected row, and "Save to
this Mac", which sends `cloud.get` and lets the ordinary file.offer
machinery land the bytes in this machine's share. Drive is a real
browser IN the page: it calls the same `now_wire_list_host` the Files
page calls (the listing hook follows whoever asked last, which is
already the wire's replacement rule for the answer), renders
name/kind rows, descends on double-click, fetches a double-clicked
file through `now_wire_get_host` with the pull's progress polled into
the card pane — one browse implementation, genuinely two renderers.

The split follows the house pattern: `cloud_model.c` (the store and
parsers, host-cc tested in `cloud_model_test.c`, mutation-watched) and
`cloud_layout.c` (pure geometry, `cloud_layout_test.c`) carry
everything decidable; `cloud_module.c` owns controls and pixels;
`wire.c` correlates ids and forwards raw frames. The guest's emitted
asks are single-template messages, so `GuestWireConformanceTests`
checks them against the host decoder and the contract's required
fields without hand fixtures. json.c grew `now_json_next_array` and
`now_json_array_string` for the card's [label, value] rows.

A get's success is correlated BY ARRIVAL: the answering file.offer
carries the host's id, not the ask's. The host only offers unprompted
when a human there pushes, so the collision costs a wrong status line,
never a wrong file — the same bargain the pull machinery already
strikes for file.begin.

## What is and is not proven

**Metal-verified 2026-08-01** on the PowerBook 1400c: the module end
to end for Drive — cloud.services across a real wire, the dropdown,
and the in-page drive browser (list, descend, Up, double-click fetch)
against the host's iCloud Drive share, fingerprinted names included.
That pass predates the full-width drive layout below (**tested, not
re-verified on metal**): the browsing logic it exercised is unchanged,
but the geometry and the Up control's position are not the ones the
PowerBook watched.

Photos and Contacts serving is **tested** (`CloudServingTests`, fake
providers over a loopback wire; refusal-code mutation watched
failing) and their real providers remain deliberately unexercised:
they need this Mac's TCC grants, and what only a signed-in,
access-granted machine can prove is ledgered in
[open-issues.md](open-issues.md). The rest of the family is
metal-verified yet.

**Drive stays a flat list, not a tree — Data Browser containers are
declared but unproven.** `spikes/databrowser-container-probe` compiles
a real call to the hierarchical surface (`AddDataBrowserItems` with a
container parent, `OpenDataBrowserContainer`/`CloseDataBrowserContainer`,
`SetDataBrowserListViewDisclosureColumn`, the container item-data
properties and notification messages) clean against this toolchain,
but none of those four symbols were in the 22 the original
`spikes/databrowser` probe confirmed CarbonLib 1.6.0 actually EXPORTS
on the PB1400c — that probe only ever asked about the flat list. A
clean compile is Level 1 (Builds); it proves nothing about whether the
real machine's CarbonLib answers those calls. Until someone reruns the
runtime probe with the container symbols added, the drive view keeps
its proven shape: full-width flat list, replace-on-navigate, Up button
— the same browsing model `files_browser_view.c` already carries
metal-verified. See `spikes/databrowser-container-probe/README.md` and
docs/guest-ui-start-here.md's proven/disproven list.
