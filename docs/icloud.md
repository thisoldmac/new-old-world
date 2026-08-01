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

## Hardened for an enormous library

A photo library can hold tens of thousands of rows; two decisions keep
that honest without spending memory this machine does not have:

- **The host's PHAsset fetch is cached per `PhotosCloudProvider`
  instance**, not re-run on every 16-row page, and is dropped only on
  a `PHPhotoLibraryChangeObserver` notification — a library that never
  changes pays for one query no matter how many pages a person turns.
  `entry()`'s count and `card`/`get`'s lookup share the same cache.
  `PHAssetResource` exposes no public byte-size property short of
  downloading the resource, so a listing's `bytes` field stays unstated
  for photos rather than reaching for the private `fileSize` KVC key
  some apps use undocumented.
- **`kCloudMaxRows` (128) does not rise for a large library.** 128
  `CloudRow` entries cost under 24KB — trivial next to the 6MB
  partition — but raising the cap only postpones the same problem at a
  bigger number; a 40,000-photo library was never going to fit in the
  Data Browser at once. What has to change instead is the wording: a
  page that hits the cap while the host still has more reads as
  "128 of many, newest first" (Photos, whose order this store knows)
  or "128 of many (more not shown)" (any other listable service),
  never as "128 rows" — the difference between a bounded prefix and a
  claim of completeness. `cloud_listing_status()` in `cloud_model.c`
  is the decision, host-cc tested in `cloud_model_test.c` and
  mutation-watched.

**Explicitly out of scope**, and not planned for this arc: thumbnails,
previews, resizing, and dithering. Nothing may pull a whole library at
photo-library scale (potentially 100GB+) onto a machine with a 6MB
partition — `cloud.get` moves exactly one photo at a time, on request,
through the ordinary file family, and that stays the only bulk path.

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
failing), now including a 10,000-row paging walk, the 4KB page bound
under wide rows, and a 3MB photo riding the ordinary offer/accept/
begin/bulk/end transfer lane — all against fakes, all mutation-watched.
The real providers remain deliberately unexercised: they need this
Mac's TCC grants, and what only a signed-in, access-granted machine can
prove is ledgered in [open-issues.md](open-issues.md). The rest of the
family is not metal-verified yet.

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

### Live search, and the review that followed

Every view filters as you type — the software module's field and
refilter shape copied deliberately (a second search idiom is drift
waiting to happen), the pure predicate in cloud_filter.c with its own
native test. An adversarial review of the whole fan-out (2026-08-01)
confirmed the gates, the guest discipline and the container-probe's
evidence, and found four real faults, all fixed the same day: the
placard now says "N of M shown" while a filter hides rows (the rule
software_module already kept); the filter test's mutation-provenance
claim was false and is rewritten from mutations actually watched
failing; drive mode's double-click affordance — lost with the card
pane — moved to the placard on selection; and a service change now
clears the needle on every route, not just the popup click. Known
smalls, ledgered not hidden: the Photos provider's fetch cache is
untested against a real library, contacts Birthday parsing is
English-month-only, long card values draw unclipped.

## Designed, not built: Photos browsing and Messages

Two arcs discussed and settled 2026-08-01, recorded here so the next
session starts from decisions instead of re-deriving them. Neither is
implemented; the fan-out in flight (view seam, drive tree, contacts,
search, photos list/download) is their substrate.

### Photos: thumbnails and downloads are two different questions

The two obvious approaches — a thumbnail browser, or the host
resizing everything on a configurable basis — are the two halves of
one design, split by WHEN processing happens:

- **Thumbnails are always host-rendered, tiny, and lazy.** The host
  dithers/resizes to the guest's actual depth (the census already
  says; 1-bit for a 68K someday, which will look charming) and the
  guest CopyBits raw indexed pixels — "conversion is the host's job"
  applied to pixels, and host-side it is exactly what
  PHCachingImageManager exists for: per-asset small-target requests,
  never a walk of the library. The arithmetic that makes it work: a
  64x64 8-bit thumb is 4 KB; a listing page of 16 as ONE bulk
  transfer — a thumbnail atlas with a control-frame manifest mapping
  item to offset — is ~64 KB, ~0.2 s at the measured 300 KiB/s.
  Guest-side, infinite scroll is a sliding window with eviction: the
  6 MB partition holds a few screens of thumbs, not a library, and
  re-fetching a 64 KB page is invisible.
- **Downloads are processed per request, with a configurable
  default.** The per-photo dropdown's options (original / fit
  640x480 / fit to screen / dithered PICT) are host-side processing
  selections; the host's iCloud page sets the default so a casual
  double-click does the sane thing. Estimated size is exact for
  uncompressed targets (dimensions x depth) and a labelled "~"
  heuristic for JPEG — show both, pretend precision for neither.
- **The preview pane** fetches one medium preview (~200x200 at guest
  depth, ~40 KB) on selection rather than scaling the tiny thumb,
  and evicts on every selection change so exactly one lives in
  memory.
- **The lane rule bites here**: bulk is one transfer wide, so thumb
  and preview fetches queue behind an in-flight download. Fine if
  the UI says so ("thumbnails resume after the download"); deadly to
  the feel if it does not.
- Contract: additive — a cloud.thumbs ask answered by a bulk
  transfer plus manifest. The current no-previews version stays the
  honest floor.

### Messages (iMessage/SMS): the first live-event push

The plumbing realities decide v0 almost completely:

- **Send** has exactly one sanctioned path: Apple Events into
  Messages.app (the AppleScript send verb). Covers iMessage, and SMS
  when the iPhone forwards texts. Needs the Automation TCC grant —
  the same consent pattern as Photos and Contacts, one more prompt.
- **Receive** has no API at all. The workable path is reading
  ~/Library/Messages/chat.db — SQLite, polled by ROWID watermark
  every few seconds while a guest is connected and the service is
  on. Needs Full Disk Access, the heaviest grant yet; the host page
  should say so plainly. Known sharp edge: modern macOS often leaves
  the text column null and stores content in attributedBody (a
  typedstream blob), so the host needs a small decoder — and when
  the schema drifts someday, the service degrades to an honest
  no-access/unavailable rather than going silently deaf.
- **Wire shape**: the first host-initiated push of live events. The
  cloud family is ask/answer; messages want msg.send {to, text}
  guest-to-host (answered sent/refused, the refusal carrying
  Messages.app's actual failure — often the only diagnostic there
  is) plus msg.incoming {from, text, when} pushed host-to-guest
  while connected. Three or four messages, additive.
- **No backfill in v0, by design**: semantics are "since this
  connection", stated plainly; disconnection drops messages on the
  floor. Guest v0 UI is a session transcript — incoming lines
  appending live, recipient field, text field, Send — with a
  Notification Manager mark or sidebar badge for incoming while on
  another page, because "your iPhone buzzed a System 7 machine" is
  the demo and should not require staring at the page. The Contacts
  service is the natural recipient picker later.
- **Plaintext v0**: the wire is a desk-local LAN, the standing
  threat model. But this is the first family carrying live personal
  correspondence — when release thinking happens, messages are the
  forcing function for the encryption story, not files.
