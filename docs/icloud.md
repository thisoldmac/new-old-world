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
- **Photos**: newest first, pages of title/date rows, each row also
  carrying the original's own width/height when the guest wants to
  compute an exact post-fit resolution (below); `cloud.detail` is a
  card of what the library knows; `cloud.preview` shows the selected
  photo IN the page (below); `cloud.get` delivers ONE photo as an
  ordinary `file.offer` into the guest's share — JPEG whatever modern
  container the library holds (HEIC included), typed `JPEG`/`ogle` so
  it opens by double-click, and **downsized automatically** per the
  host's per-service Downloads setting (Original / Fit 640x480 / Fit
  1024x768 / Fit 1440x1080 / Fit 2048x1536, default Fit 640x480,
  `cloud.photos.downloadSize`), applied in the get pipeline before the
  JPEG is encoded — unless the ask itself carries the additive `size`
  token (same five renders), in which case the asker's choice
  outranks the setting; an unrecognized token refuses with a reason.
  Every `fitN` token is a FIT BOX (aspect preserved, never upscaled);
  the wire never states the exact resolution a fit produces for a
  given photo — a guest that wants to SHOW that number computes it
  itself from the entry's own width/height and the chosen box, the
  same fit arithmetic `cloud.preview` already does host-side, just run
  on numbers the guest already has rather than sent a sixth way. An
  original iCloud has not materialized
  starts its download and refuses `busy`, the same bargain the share
  strikes for Drive placeholders.
- **Contacts**: alphabetical, the card is the deliverable —
  phones/emails/addresses as [label, value] rows in the person's own
  labels. `cloud.get` is refused until the classic side can read a
  vCard. `cloud.preview` IS served, unlike `cloud.get`: the contact's
  own thumbnail (`CNContactThumbnailImageDataKey`), run through the
  exact same decode/fit/dither pipeline Photos previews use — a
  thumbnail is pixels the host already knows how to render, where a
  vCard is a document format the classic side cannot open at all, and
  that is the whole reason the two verbs answer differently for the
  same service. A contact with no thumbnail (most of them) refuses
  `cloud.refuse` `not-found` reason "no photo" — an expected, well-
  formed outcome, and the guest's card pane draws its own placeholder
  for exactly that reason string rather than treating it as a failure.

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
what the wire will do with the grant), and a denied service gets an
Open Settings door, because the API only ever asks once. The app MUST
sign with the hardened-runtime personal-information entitlements
(`now-host/NewOldWorld.entitlements`): without them macOS denies
Photos and Contacts instantly — no prompt, no System Settings row —
which reads exactly like a broken button and cost a metal session to
diagnose (2026-08-01). Drive's switch is the share itself — the same
act as picking iCloud Drive in the Files footer, with the previous
folder remembered and restored.

Serving is ungated past the handshake, like the share (decided
2026-08-01): the switches are the consent, per service.

The Photos row also carries the **Downloads picker** (Original / Fit
640x480 / Fit 1024x768 / Fit 1440x1080 / Fit 2048x1536): what a
`cloud.get` delivers when the ask names no size of its own, applied
host-side before the JPEG leaves. The guest's Size popup (below) can
override it per ask — "Original" from the classic side is the asker
saying so, which is the same consent — and the default still fits the
screens the fetch is for: a 48-megapixel original into a 6 MB
partition is a mistake a default should not require declining every
time. `PhotosCloudProvider.DownloadSize.allCases` drives the picker
directly, so a token added there needs no second edit to appear here.

## The guest page

One Workshop module (`now-guest-ppc/src/cloud/`), the eleventh page:
a service dropdown rebuilt from each `cloud.report`, a two-column Data
Browser for the chosen service's rows (paged straight through, the
Files browser's rule), a card pane for the selected row, and "Save to
this Mac", which sends `cloud.get` and lets the ordinary file.offer
machinery land the bytes in this machine's share. Drive is a real
file browser IN the page: it calls the same `now_wire_list_host` the
Files page calls (the listing hook follows whoever asked last, which
is already the wire's replacement rule for the answer) and renders
the Files page's exact columns — Name with the row's native icon
(`GetIconRef` by type/creator, cached per distinct pair; folders wear
the folder icon), Kind, Size, Modified (`LongDateString`) — under a
breadcrumb row built by the shared `now_files_path_label` from the
listing's own root field ("iCloud Drive:Attic:Old Sites"). The
toolbar carries Back, Forward and Up: Up and every descend are plain
navigations that push onto a bounded 16-step history (`cloud_nav.c`,
pure and host-cc tested), Back and Forward retrace it, and the pair
dims — never hides — when its stack is empty. Double-click still
opens a folder or fetches a file through `now_wire_get_host`, with
the pull's progress on the status placard — one browse
implementation, genuinely two renderers.

Drive gets photos' download-target furniture, too (2026-08-02): a
destination row beneath the breadcrumbs, "Save into:" plus the
folder's path, with a Choose... button on the shared right edge
Refresh's own column already uses. Unset means the downloads folder —
byte-identical to every pull before this existed, since that is what
a pull already meant here — through a NEW wire-level override,
`now_wire_get_destination`, consumed at `get_begin` beside
`now_wire_get_host`: the pull path's own twin of
`now_wire_cloud_get_destination` above, same reasoning (guest-side
only, no contract change, the receiver sovereign over its own disk),
different delivery. The status placard's "Receiving X into Y" /
"Received X - it is in Y" name whichever folder the pull actually
landed in, resolved once at `get_begin` so the outcome can never
disagree with where the bytes went even if the chooser is used again
mid-transfer. Files and Drive both pull through the same
`now_wire_get_host`, so the get-note hook now follows whoever asked
last, the listing hook's existing rule — each page reclaims it
(`conn_set_get_note`) the instant it calls `now_wire_get_host`.

The drive columns live on the drive view's OWN Data Browser, a second
mostly-hidden control beside the shell's shared two-column one, and
that is a deliberate trade: the only way off a column is
`RemoveDataBrowserTableViewColumn`, which is not among the 22 symbols
`spikes/databrowser` proved CarbonLib 1.6.0 exports on the PB1400c,
and a lazily-bound CFM call to an absent export is a crash at click
time. One control per column set, every call in the proven 22.

**Photos is list + preview-on-select** (`cloud_photos_view.c`, behind
the same `CloudViewOps` seam — a `select` op the shell calls on every
selection change): selecting a row asks `cloud.preview` with the card
pane's dimensions and the screen's ACTUAL depth (8 for any screen that
can index, 1 below that), and the host's answer — raw indexed rows it
has already decoded, resized and dithered — lands in one offscreen
GWorld and replaces the text card by one centered CopyBits, the
Screenshots well's blit shape. Exactly ONE preview lives in memory at
a time, evicted on every selection change, service change, or filtered
deselect: the 6 MB partition holds a photo, not a library. The
transfer arrives as one bulk bracket and lands as one invalidation of
the pane — never a repaint per wire frame — and while a download holds
the one-transfer-wide lane the ask refuses `busy`, which the pane
words honestly as "Preview after the download". The decidable half
(`preview.begin` validation before any allocation, the depth mapping,
the pane-fit arithmetic) is pure in `cloud_preview.c`, host-cc tested
in `cloud_preview_test.c`, mutation-watched. Between the ask and the
pixels the pane says "Loading preview..." — drawn state, invalidated
once at each transition, cleared by the arrival or by the refusal
reason drawing in its place.

The download UX (2026-08-02) lives in the same view, below the pane:

- **A Size popup** (Original / Fit 1024x768 / Fit 640x480 / Host
  default, MENU 136 — the services-popup recipe) puts the additive
  `size` token on Save's `cloud.get`; "Host default" omits the field,
  which is the ask every older guest already sends. The choice is
  session-state, deliberately not persisted — a prefs field was
  weighed and skipped, since the host default is the remembered
  preference and the popup is the per-ask exception.
- **A destination row** shows where a saved photo lands ("Save into:"
  plus the folder's path, truncated middle) with a Choose... button —
  the shared `NavChooseFolder` door (`now_files_choose_folder`, the
  downloads chooser refactored onto the same body). Guest-side ONLY,
  no contract change, and the reasoning is in `wire.c` where the
  redirect happens: the contract's share bound governs what the SENDER
  may reach unbidden; this delivery is one the guest ASKED for, and
  the receiver is sovereign over its own disk — the pull path already
  lands in Downloads, outside the share, on the same argument. The
  wire's by-arrival correlation redirects exactly THAT offer through
  `now_files_receive_begin_at` (same-folder temp staging included);
  choosing the share root clears the override, so that path stays
  byte-identical to before the chooser existed.
- **A real moving bar plus a byte count** while the get's offer is
  received: the share panel's `kControlProgressBarProc` recipe and its
  idle discipline verbatim (value 0..1000, mutated only on change),
  fed by the read-only `now_wire_receive_active` — the inbound twin of
  `now_wire_get_active` — with the byte line ("312K of 3200K") from
  pure `cloud_dl_bytes_line`, repainted only when the string changes,
  in its own small rect.
- **The outcome replaces the status.** "Receiving X into Y" (worded
  from the actual destination) used to persist after the transfer
  ended; now `wire.c` records a one-line outcome plus a sequence
  number at every receive ending (`now_wire_receive_outcome`) —
  success, refusal, cancel, corrupt, lost link — and the shell's idle
  swaps the status for it once, on the sequence moving. One
  implementation serves the placard and the pane.

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
  some apps use undocumented — and stays that way: nothing about the
  polish arc's entry-dimensions field changes this, because
  `bytes` and `width`/`height` are answered from two different APIs
  with two different costs. `pixelWidth`/`pixelHeight` ARE public
  `PHAsset` properties, answered from metadata already in hand with no
  network and no resource download, which is why `width`/`height` get
  filled for every photo row while a Size column (bytes) stays blank —
  the same library, two properties, only one of them free to read.
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

**Still out of scope**: anything that walks the library as pixels. A
preview is ONE photo, on selection, evicted on the next; a thumbnail
grid would be all of them, and it is deferred indefinitely (below).
Nothing may pull a whole library at photo-library scale (potentially
100GB+) onto a machine with a 6MB partition — `cloud.get` moves
exactly one photo at a time, on request, through the ordinary file
family, and `cloud.preview` moves at most one pane's worth of indexed
pixels, host-clamped to 640x480.

## What is and is not proven

**Metal-verified 2026-08-01** on the PowerBook 1400c, in two
sessions. First: the module end to end for Drive — cloud.services across a real wire, the dropdown,
and the in-page drive browser (list, descend, Up, double-click fetch)
against the host's iCloud Drive share, fingerprinted names included.
That pass predates the full-width drive layout and the real-browser
work above (**tested, not re-verified on metal**): the browsing logic
it exercised is unchanged, but the four-column control, its icons,
the breadcrumb row, Back/Forward and the toolbar geometry are not the
ones the PowerBook watched. The column recipe and the icon calls are
the metal-verified Files/Processes recipes reused verbatim, which is
evidence about the ingredients, not the dish.

Second, the same evening: with the entitlements fix in, the grant
prompts fire, and Michelle reports the granted services — Photos and
Contacts over the fan-out's views — working as intended against the
real machine. Detailed notes pending; itemized claims below stay at
their tested level until they arrive.

Photos and Contacts serving is **tested** (`CloudServingTests`, fake
providers over a loopback wire; refusal-code mutation watched
failing), now including a 10,000-row paging walk, the 4KB page bound
under wide rows, and a 3MB photo riding the ordinary offer/accept/
begin/bulk/end transfer lane — all against fakes, all mutation-watched.
The real providers remain deliberately unexercised: they need this
Mac's TCC grants, and what only a signed-in, access-granted machine can
prove is ledgered in [open-issues.md](open-issues.md). The rest of the
family is not metal-verified yet.

The download-UX arc (2026-08-02, same day, later) is **tested,
nothing more**: the size override is loopback-proven end to end
(token reaching the provider, absent-size default, unknown-token
refusal — all mutation-watched), the guest's pure halves (the popup
item map, the bar's 0..1000 scaling and clamps, the byte line's
round-up, the furniture geometry and its pane-never-under-a-control
rule) are host-cc tested with watched mutations, and the PPC guest
cross-compiles. Everything a person would SEE — the loading line,
the bar moving, the destination redirect landing bytes in a chosen
folder, the outcome replacing "Receiving..." — has run nowhere, and
is exactly what the next metal session should watch for.

The preview arc (2026-08-02) is **tested, nothing more**: the
ditherers are pure units with watched mutations (`ClassicDitherTests`
— zeroed Floyd-Steinberg weights and an ignored Atkinson carry both
named by the mean/mix properties), the serve is loopback-proven
(bytes intact through begin/bulk/end, lane exclusivity
mutation-watched, the no-preview default refusal), the resize/JPEG
pipeline runs against in-test JPEG and HEIC fixtures
(`PhotosProcessingTests`), and the guest's begin-validation and fit
arithmetic are host-cc tested (`cloud_preview_test.c`,
mutation-watched). The guest half past those pure units — the GWorld,
the CopyBits, the pane's honesty under a held lane — **builds** and
has run nowhere; and the whole path against a REAL granted library
(a preview of an actual HEIC on an actual screen, the busy bargain
against a real un-materialized original) is exactly what only metal
and a signed-in Mac can prove.

The polish2-foundations arc (2026-08-02, contract + host only, no
guest UI) is **tested, nothing more**, and narrower still — no guest
half exists yet for any of it. The two new Downloads/`size` boxes
(fit1440, 1440x1080; fit2048, 2048x1536) ride the exact code path the
original three already used
(`chosenSize`, `processedJPEG`'s box arithmetic), loopback-proven the
same way (`CloudServingTests`) and against `PhotosProcessingTests`'
in-test fixtures for the resize itself. `CloudEntry.width`/`height`
are loopback-proven to ride the wire and to stay ABSENT (never a
guessed zero) for a service that does not state them; `PhotosCloudProvider
.list` filling them from `PHAsset.pixelWidth`/`pixelHeight` reads
against a real library and is therefore in the same untested-real-
library bucket as the rest of `PhotosCloudProvider`, ledgered in
[open-issues.md](open-issues.md). Contacts `cloud.preview` is
loopback-proven end to end for the WIRE and for the REUSED pipeline
(a synthetic thumbnail run through `PhotosCloudProvider.rgbPixels` +
`ClassicDither.dither`, exactly the code `ContactsCloudProvider
.preview` calls, answers a `cloud.preview` for the "contacts" service
indistinguishably from photos) and for the not-found "no photo"
refusal's exact wording; the real
`CNContactStore.unifiedContact(withIdentifier:keysToFetch:
[CNContactThumbnailImageDataKey])` call against an actual card is
untested here — it needs this Mac's Contacts TCC grant, the same
bucket Photos' real-library path already sits in, and what only that
grant can prove is ledgered alongside it.

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
its proven shape: full-width flat list, replace-on-navigate, with
Back/Forward/Up walking a history rather than a disclosure walking a
tree — the same browsing model `files_browser_view.c` already carries
metal-verified. The same evidence rule is why the drive columns live
on their own control (above): `RemoveDataBrowserTableViewColumn` is
declared but was never probed either. See
`spikes/databrowser-container-probe/README.md` and
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

## Photos as shipped, and what was deliberately not built

The 2026-08-01 design here sketched a thumbnail-grid browser plus
per-request download processing. **Michelle revised it 2026-08-02**,
and what shipped is the revision, not the sketch:

- **No thumbnail grid, no hand-drawn canvas — deferred INDEFINITELY.**
  The Photos view stays LIST + PREVIEW-ON-SELECT: the rows are the
  ordinary Data Browser listing, and selecting one shows that one
  photo, dithered to the guest's depth, zoomed to fit the card pane,
  replacing the text card. One preview in memory at a time, evicted
  on every selection change. Everything the grid design existed to
  ration — sliding windows, atlas transfers, manifest frames — went
  away with the grid; if a grid ever returns it starts from a new
  decision, not from this paragraph.
- **What survived from the sketch**, because it was the sound half:
  the host renders EVERYTHING (decode, resize, dither — pixels are
  text conversion's sibling, the modern side's job); the wire carries
  raw indexed rows the guest can only CopyBits; the lane rule is
  surfaced honestly ("Preview after the download"); the preview is
  contract-additive (`cloud.preview`, `preview.begin`/`preview.end`,
  the fourth bulk payload kind).
- **Downloads are processed per the host's configurable setting, with
  a per-ask override since 2026-08-02.** `cloud.get` always converts
  to JPEG (HEIC included) and downsizes per the iCloud page's
  Downloads picker (Original / Fit 1024x768 / Fit 640x480, default
  Fit 640x480) unless the ask carries the additive `size` token from
  the guest's own Size popup. The estimated-size arithmetic the
  original sketch paired with the dropdown remains unbuilt,
  deliberately — the popup states renders, not byte guesses.

## Designed, not built: Messages

Settled 2026-08-01, recorded so the next session starts from decisions
instead of re-deriving them. Not implemented.

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
