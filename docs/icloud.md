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
  host's per-service Downloads setting (Original / Long side 1600 /
  Long side 1024 / Long side 640, default Long side 640,
  `cloud.photos.downloadSize`), applied in the get pipeline before the
  JPEG is encoded — unless the ask itself carries the additive `size`
  token (same four renders), in which case the asker's choice
  outranks the setting; an unrecognized token refuses with a reason.
  Every `longN` token names the **LONGEST EDGE** (aspect preserved,
  never upscaled): a portrait 3024x4032 at `long640` is 480x640, and
  the same photo landscape is 640x480. The `fitN` fit boxes this
  replaced (2026-08-02) are **retired, not aliased** — they gave a
  portrait photo the SHORT edge's number, delivering 360x480 for that
  same photo, which is the defect a person met on metal. A peer still
  sending one meets the unknown-token refusal naming the valid set,
  which is why a deliberate semantic break on a days-old field needed
  no contract-revision bump. The wire never states the exact
  resolution a stop produces for a given photo — a guest that wants
  to SHOW that number computes it itself from the entry's own
  width/height and the chosen long edge, on numbers it already has
  rather than sent a fifth way. The report's `defaultSize` carries the
  host's own configured token, so a guest can PRESELECT it instead of
  offering a "host default" item it cannot name. An
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

The Photos row also carries the **Downloads picker** (Original / Long
side 1600 / Long side 1024 / Long side 640): what a
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
a service dropdown rebuilt from each `cloud.report`, a Data Browser
for the chosen service's rows (paged straight through, the Files
browser's rule) — the shell's shared two-column one (Item/Detail) for
any service with no tailored view, Drive's, Photos' and Contacts' own
wider ones for those three — a card pane for the selected row, and
"Save to this Mac", which sends `cloud.get` and lets the ordinary
file.offer machinery land the bytes in this machine's share. Drive is
a real file browser IN the page: it calls the same `now_wire_list_host` the
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
opens a folder or fetches a file through `now_wire_get_host` — one
browse implementation, genuinely two renderers.

**Drive stopped being a full-width list with a global destination row
(2026-08-02).** It now uses the exact list/detail split every other
view uses (`cloud_layout.c` computes one split and reuses it; drive
mode differs only in `list_top`, pushed down by the breadcrumb row
above it, and in what its own furniture fills the pane with below).
The pane shows the SELECTED item, textually: for a folder, its name
and kind; for a file, name/kind/size/date and the double-click
affordance line ("Double-click fetches X to this Mac.") — text that
had moved to the placard in the 2026-08-01 review below and comes
back into the pane here, so the placard stops carrying it and
selection touches only the pane. Deliberately no image preview for an
IMAGE-typed row (PICT/JPEG/GIFf/PNGf): a drive row carries no cloud
item id — `cloud.preview` is a `cloud.*` verb, and Drive's transport
is the file family, not `cloud.*` — so showing one pixel of a drive
file would need a real fetch-and-decode path this arc does not build.
`cloud_drive_view.c`'s `draw_item_card` names the seam for whichever
later arc wants to close it.

Drive gets photos' download-target furniture, too (2026-08-02): a
destination row IN THE PANE (moved off the old breadcrumb-adjacent
toolbar strip once the pane existed to hold it), "Save into:" plus
the folder's path, with a Choose... button on the shared right edge
Refresh's own column already uses — the 5d948ed rule applied to the
pane's own furniture column, one row shorter than list/photos mode's
own (no Save button, no Size popup: Up stays in the toolbar and a
drive pull always keeps the file's exact bytes). Unset means the
downloads folder — byte-identical to every pull before this existed,
since that is what a pull already meant here — through a NEW
wire-level override, `now_wire_get_destination`, consumed at
`get_begin` beside `now_wire_get_host`: the pull path's own twin of
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

**The pull's moving progress lives in the pane too (2026-08-02),
reusing Photos' own bar-plus-byte-line recipe rather than
reinventing it**: the same pure `cloud_dl_bar_value`/
`cloud_dl_bytes_line` (`cloud_model.c`) feed a `kControlProgressBar-
Proc` control and a byte-count line, both idle-gated on a
shown-value diff exactly as Photos' furniture is. The one honest
difference is which wire entry point feeds them — Drive's own bar
watches `now_wire_get_active` (the ordinary pull the Files page's
own pane already narrates), not Photos' `now_wire_receive_active`/
`from_get`, because Drive pulls through `now_wire_get_host`, the same
entry point Files uses, not through `cloud.get`. The placard no
longer gets a per-idle byte-count overlay while a drive pull runs; it
shows only durable news (folder listings, errors, the wire's own
get-note outcomes) now that the pane carries the moving number.

The drive columns live on the drive view's OWN Data Browser, one of
three view-owned controls beside the shell's shared two-column one
(Photos and Contacts each keep their own too, below), and
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
reason drawing in its place. The GWorld, the fetch bookkeeping and the
CopyBits landing moved out of this file into `cloud_preview_well.c`
(2026-08-02): ONE preview well shared by any view that can show one,
not one per view, because the wire itself refuses a second
`cloud.preview` while one is in flight (`now_wire_cloud_preview`) —
Photos and Contacts asking through their own copies of that state
would either race each other or reinvent the same "one at a time" rule
the wire already enforces.

**Photos also has its own Data Browser** (2026-08-02, the same
one-control-per-column-set trade as Drive's): Name, Size — the
entry's `bytes` when the host stated them, "--" otherwise, since
photos rows never state one (below) — and Modified
(`LongDateString`), occupying the exact rect the shell's shared
two-column browser used to draw into. Selection routes through the
SHELL's own notification handler unchanged (this view's rows are the
shell's shared listing, indexed exactly as the two-column browser
indexed them — only the columns are this view's own); only the
item-data callback and the control itself are new, wired up in
`cloud_photos_view_bind` before `create` runs so the control's own
Data Browser callbacks can be set in one call, the drive view's
pattern throughout.

**The Size popup's items show the SELECTED photo's exact delivered
resolution.** Original reads the entry's own width/height
("3024 x 4032"); each `longN` item reads what that stop will actually
produce for THIS photo, computed on the guest from the entry's
width/height and the long edge (`cloud_photo_long_edge` in the
Toolbox-free `cloud_photo_size.c`, host-cc tested in
`cloud_photo_size_test.c`, mutation-watched with a portrait case that
fails under the box-fit math it replaced) — aspect-preserving and
NEVER upscaling, the same truncating arithmetic the host's own
`PhotosCloudProvider.scaled` runs, so the label and the file cannot
differ by a pixel without a wire round trip (the wire's own token
stays coarse by contract; see the `CloudGet.size` doc in
`contract/asyncapi.yaml`). Rebuilt via `SetMenuItemText` on every
selection change (the services-popup recipe already used for the
dropdown), falling back to MENU 136's own literal wording ("Long side
1024") on no selection or when an entry never stated its dimensions —
never a guessed number.

**The caption has its own rectangle** (`CloudLayout.size_label`,
2026-08-02). It used to be drawn into `size_popup` itself, which is
the popup's whole control rect — so the caption and the popup's own
title overprinted into garbage on metal. The "Into" row one line below
(`dest_row` + `dest_btn`) was already the right shape and is what this
copies: caption at the group box's left inset, control flush to the
shared right edge. `cloud_layout_test.c` asserts the non-overlap as a
RELATIONSHIP (`size_label.right <= size_popup.left`, same row), which
is the only form of that assertion a mutation can fail.

The download UX (2026-08-02) lives in the same view, below the pane:

- **A Size popup** (Original / Long side 1600 / Long side 1024 / Long
  side 640, MENU 136 — the services-popup recipe) puts the `size`
  token on Save's `cloud.get`, and ALWAYS an explicit one. There is no
  "host default" item: an item that cannot say on screen what it will
  deliver is not an answer to "at what size?". The host's setting
  arrives as data instead (`cloud.report`'s `defaultSize`) and is
  PRESELECTED — the popup opens on it, and a report that names a token
  this guest does not offer opens on the largest bounded stop, never
  on Original (a 48-megapixel original landing unasked on a 6 MB
  partition is the one fallback that could hurt). A pick the person
  has made outranks a later report, so Refresh never moves the size
  out from under them. The choice is session-state, deliberately not
  persisted — the host default is the remembered preference and the
  popup is the per-ask exception.
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

**Contacts is a real address-book view** (`cloud_contacts_view.c`),
the twelfth page's third tailored view alongside Drive and Photos
(2026-08-02). The LIST is this view's own Data Browser — Name and
Company columns, not the shell's generic Item/Detail — built with the
drive browser's own recipe (own control, own UPPs, disposed before
them, the fill-hilite call) but reading the shell's shared `CloudStore`
directly rather than owning row storage of its own: Contacts has no
fetch the way Drive does, so the shell's existing `cloud.listing`
paging, the live search's diff and the Data Browser add/remove
batching all keep working unchanged — `active_browser()` just has a
third mode to hand out. Picking a row still runs through the shell's
own `g_selected`/`ask_card()`/`CloudViewOps.select` sequence, reached
via two function pointers — `CloudContactsHost.row_selected` and
`row_deselected` — so a rebuild's own spurious deselect (the same
hazard the shell's own browser already guards against, `in_rebuild`)
cannot double-fire a card ask, and so an ordinary click's own
Deselected(old)/Selected(new) pair (the Data Browser fires both
around every selection change) cannot clear the NEW selection the
same click just made: `row_deselected` hands the shell the raw index
rather than clearing unconditionally, and `cloud_module.c`'s
`note_row_deselected` is the ONE place that decides whether that
index is still the current selection — the same comparison the
shell's own browser's notification already made, now made once for
both controls instead of once correctly and once (until this fix)
missing.

**Contact details load with the LIST, not per selection — only the
photo stays lazy.** A selection with a cached card draws instantly and
asks the wire nothing; only a cache miss still asks (`ask_card`,
unchanged). The cache (`cloud_card_cache.h/.c`, Toolbox-free, host-cc
tested in `cloud_card_cache_test.c`, mutation-watched) is a bounded
table keyed by item id, sized to `kCloudMaxRows` (128) — one entry per
row a contacts listing can ever hold at once, so the background walk
below never has to evict a card still on the same page to make room for
another one from it. One entry costs roughly 2.5KB
(`kCloudMaxCardRows` × `sizeof(CloudCardRow)` plus the item id), so 128
of them is about 320KB — around 5% of the 6MB partition, alongside a
128-row listing and a Data Browser. Eviction (oldest-stamp-first) still
exists and is tested even though the production cap never triggers it
in ordinary use: a cache correct only when never over-asked is a
narrower claim than one correct when it is, and future callers should
not have to discover the difference the hard way.

The cache is filled by a background PREFETCH (`drive_card_prefetch`,
`cloud_module.c`) that walks the listed rows in order, one
`cloud.detail` ask at a time, and only while `now_wire_cloud_pending()`
reports the wire's single cloud-ask slot free — no page still loading,
no earlier prefetch ask still awaiting its answer, and (implicitly,
since the same slot serves both) no selection's own ask in flight
either. It fires from `cloud_idle`, contacts-only and page-visible-only,
skips whatever the cache already holds, and never bursts: exactly one
`cloud.detail` in flight at a time, full stop. A live selection always
outranks it — `ask_card` clears the prefetch's own in-flight flag the
moment it sends its own ask, so a click that lands mid-walk is answered
as a selection (displayed AND cached), never mistaken for the
prefetch's own reply, and the interrupted prefetch ask's reply (if the
host still sends one) is silently dropped by the wire's own
second-ask-replaces-the-first rule rather than corrupting either path.
A fresh listing (a first page, Refresh, or a service switch) resets
the cache and the walk's cursor together, since an old cursor may not
even name the same contacts. Whichever ask actually lands a card also
caches it — the prefetch's own answers and an ordinary selection's
cache-miss answers both feed the same table — so nothing asked once is
ever asked twice.

The CARD is the classic Address Book's shape: a photo well top-left,
the name beside it in the large system font with the organization
under it in the small one, then — below both — **one titled group box
per section**, in the order Phone, Email, Address, Other, each holding
its own label/value rows (the label at the box's left inset, the value
a second column 70 points right of it). A section with no rows is
absent, not an empty box; a contact whose card has not arrived yet
draws the well and the name alone rather than four empty frames.

`cloud_contacts_card_layout` (pure, host-cc tested in
`cloud_contacts_card_test.c`, mutation-watched) decides all of it: it
places the well at 48x48 (not 64: the smallest honest pane's ~184pt
width leaves a 64pt well too little room for a name before
truncation), degrades it to fit a pane too small to hold the
configured size rather than overflow, and answers the section list —
title, rect, and the index range of rows inside each. Which section a
row belongs to is read from its VALUE, never its label, because the
contract says the labels are the person's own ("home" appears on a
phone and an email alike); an address is recognised as
`CNPostalAddressFormatter`'s comma-joined shape, with a company name
containing a comma and a Birthday's long date both excluded by
construction. A stack too tall for the pane is truncated rather than
spilled — there is no scroller — but the box paddings are chosen so
that the worst card the wire can deliver (`kCloudMaxCardRows` = 16
rows across all four sections) still fits a 640x480 screen's pane
without losing a row, and the test says so.

The boxes are real Appearance group boxes
(`kControlGroupBoxTextTitleProc`, the constructor `software_module.c`
already proves here), held as a **fixed pool of four** created once at
view create: a selection only retitles, moves and shows or hides them,
because a contact's section set changes on every click and
NewControl/DisposeControl on that seam is exactly the redraw churn
`docs/guest-ui-start-here.md` warns about. The pool is synced from one
change-gated seam keyed on everything a box shows, so an unchanged
answer costs a `memcmp` per idle pass; a pool member that failed to
create costs its own frame and nothing else — the rows inside it still
draw. The ROWS stay hand-drawn text: they are content, not controls.

The well's pixels are the shared preview well above,
asked with `service="contacts"` on every selection change exactly the
way Photos asks with `service="photos"`; while the ask is in flight,
refused (most contacts have none — a contact with no photo answers
`cloud.refuse` `not-found` "no photo" as an EXPECTED outcome, not an
error), or nothing has been asked for yet, the well draws a hand-drawn
person-silhouette placeholder — a head and shoulders in gray QuickDraw
ovals, clipped to the well — rather than showing nothing.

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
evidence about the ingredients, not the dish. It also predates the
split-view pane (2026-08-02, above) — the browsing logic is again
unchanged, but the pane's own card text, its destination furniture
and its download bar are new pixels nobody has watched draw.

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
half exists yet for any of it. Its two extra fit boxes have since been
retired along with the other three (the long-edge arc, same day): the
Downloads/`size` stops are now `original` / `long1600` / `long1024` /
`long640`, riding the same code path (`chosenSize`, `processedJPEG`,
now `scaled`'s longest-edge arithmetic), loopback-proven the same way
(`CloudServingTests`, including the refusal a retired `fitN` token
earns) and against `PhotosProcessingTests`' in-test fixtures for the
resize itself — portrait and landscape at a stop, and the
never-upscale case. `CloudEntry.width`/`height`
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

The Contacts guest UI arc (2026-08-02, atop polish2-foundations) is
**tested, nothing more** — narrower even than that: the pure card
layout (`cloud_contacts_card_layout`'s well/name/rows placement) is
host-cc tested in `cloud_contacts_card_test.c`, mutation-watched, and
the PPC guest cross-compiles clean with zero warnings, but nothing
past cross-compilation has run anywhere — not against a live host
wire, not on the emulator, not on the PowerBook. Contacts' own Data
Browser (Name/Company columns), the photo well's CopyBits landing, the
hand-drawn silhouette placeholder, and the preview well's extraction
out of `cloud_photos_view.c` (shared state Photos now also depends on)
are all unverified past "builds" — the same level `docs/guest-ui-
start-here.md` warns is worth the least trust, because the surprises
in this project have consistently come from code that looked obviously
correct and had never run on the real machine. In particular: the
well-extraction refactor changed WHICH view's `note` callback fires
when a preview settles (rebound per `_select` call, cloud_preview_
well.c) — a real behavior change for Photos, not just a file move, and
Photos' preview path has not been re-verified on metal since.

The contacts selection fix and the card prefetch/cache (2026-08-02,
p3-contacts-fix) are **tested, nothing more**: the deselect-guard bug
— selecting a second contact left the card pane on "Select a name..."
because `cloud_contacts_view.c`'s own Deselected handler cleared the
selection unconditionally, racing the Data Browser's own
Deselected(old)/Selected(new) pair — is fixed and the fix's shape
(centralizing the comparison in `cloud_module.c`'s
`note_row_deselected` rather than duplicating it) is exercised only by
the native gates and a clean cross-compile; the actual click sequence
on a live Data Browser has not been watched, on the emulator or the
PowerBook, since before this fix existed. The card cache's own logic
(`cloud_card_cache_test.c`: insert/lookup/evict/bounds) is host-cc
tested and mutation-watched — real coverage of real logic — but the
prefetch driver that calls it (`drive_card_prefetch`, the wire-idle
gating, the one-ask-in-flight discipline, the live-ask-supersedes-
prefetch handoff in `ask_card`/`note_card`) is Toolbox-adjacent
sequencing that no host cc can exercise, and has run nowhere but a
cross-compile. What only a live wire and a real contacts list can
prove: that the prefetch actually walks ahead of a person's clicking
rather than behind it, that "one ask in flight, ever" holds against a
real host's actual reply timing (not just the wire's own
correlation rule, which is what this file has reasoned from), and that
a cache hit's card reads identically to a freshly-asked one on the
real machine's own MacRoman rendering.

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

### The polish2 integration (2026-08-02), and what only landed here

`claude/polish2-drive-dest`, `claude/polish2-photos-cols` and
`claude/polish2-contacts` merged onto `claude/polish2-foundations` are
**tested, nothing more**: `scripts/test-all` is green (all 79 native
tests including the seven `cloud_*` ones, both guest cross-builds, the
host suites and the Xcode app target) on the merged tree, and
`audit_source.py` over every touched `now-guest-ppc/src/cloud/*.c` file
found no new hazard — the 22 lexical findings it raises are all
pre-existing, already change-guarded or already-exempted patterns
(popup `TrackControl` calls using `(ControlActionUPP)-1L`, push-button
ones using `now_pump_action()`, `HiliteControl`/`SetControlValue` calls
gated on a `g_shown_*`/`g_bar_value` diff, `RGBForeColor`/`RGBBackColor`
before every `CopyBits`). None of this ran on the emulator or the
PowerBook.

The merge itself had to reconcile two branches that grew the same shape
independently: `view_own_browser()`/`active_browser()`/
`show_own_browser()` in `cloud_module.c` generalized from two
view-owned browsers (Drive, Photos) to three (Drive, Photos, Contacts)
rather than picking either side's two-way check, and `cloud_photos_view
.c` kept photos-cols' own Data Browser (Name/Size/Modified, the Size
popup's exact-resolution labels) while adopting polish2-contacts'
extraction of the GWorld/fetch state into the shared
`cloud_preview_well.c` — so Photos' preview now goes through the same
rebound-`note`-callback path Contacts does, a real interaction between
the two arcs that neither branch's own tests could see alone (each
tested against the shell's OTHER pieces, not each other's). This is
the specific claim that needs a metal session before it is more than
"builds and passes tests written in each branch's own isolation": pick
a photo, watch the preview arrive on the new Data Browser, switch to
Contacts, pick a card, and confirm the well's eviction/rebind still
hands the right pane its pixels and not the other view's.

### Every modern Modified date silently dropped, fixed (2026-08-02)

Watched on metal the same day: the Photos list drew "--" in Modified
for every 2026 photo. Traced to `ClassicDate.guestWireSeconds`
(`now-host/Sources/Host/FileConverter.swift`), which stopped at
`Int32.max` — January 1972 in classic (1904-epoch) seconds — because
the deployed guest read the field with `strtol` into a signed 32-bit
`long`. Every date after that came back `nil`, `modified` was omitted
from the wire entirely, and the guest drew the "unstated" dash. This
was not Photos-specific: `CloudServices.swift`, `HostShare.swift` and
`FilesModel.swift` all route through the same function, so the drive/
files browser and every cloud listing carried the same silent gap.

A classic file date is actually **unsigned** seconds since 1904, good
to early 2040 — the host's ceiling was simply wrong, not conservative.
The fix moves the ceiling out to match (`ClassicDate.macSeconds`'s own
`< 4_294_967_295`) and gives the guest an unsigned reader to match it:
`now_json_find_u32` (`now-guest-ppc/src/core/json.c`, and
`now68k_json_find_u32` on the 68K side, which already existed for
CRC32 and only needed pointing at this field) — a `strtoul`-shaped
digit loop masked to 32 bits by hand, so it behaves the same on the
32-bit `long` the guest is built for and the 64-bit one this host's
own `cc` runs its native tests under. Every classic-seconds field
either guest reads off the wire now goes through it: the PPC guest's
cloud listing rows, its browse/pull replies (drive/files browser and
`file.pull`), and both guests' `file.offer` push.

A second, independent site carried the identical bug and is not
reached by `ClassicDate` at all: `GuestFileUploadCommands.begin`
(`now-host/Sources/Host/Automation/GuestFileUploadCommands.swift`),
the MCP agent-upload path's own inline `modified <= Int32.max`
clamp, guarding a raw already-classic-seconds `Int` the caller
supplies directly rather than a `Date`. Same fix, same reasoning
(the ceiling is `UInt32.max`, not `Int32.max`) — found by grepping
`now-host/Sources` for `Int32.max` once the first site was fixed,
not by the original diagnosis, so treat this class of bug as "any
inline reimplementation of the ceiling," not "one function."

**Tested, nothing more.** Host XCTest covers the boundary
(1904/1972/2026/2040/past-2040) and a `HostShare.list()` integration
test proving a 2026 date now survives to the wire; guest
`json_native_test` covers the unsigned parser itself at 2^31-1/2^31/
2^32-1/overflow; `cloud_model_test` and the 68K `test_putrx` each add
a call-site regression case, mutation-watched by reverting to the old
signed call and confirming the specific assertion names it. Two
PRE-EXISTING tests turned out to encode the bug as correct behavior
and had to be corrected alongside the fix, not just the new tests
added for it: `AgentIntegrationArtifactTests
.testApprovedTransferSettlesOnlyOnFileDoneAndCannotReplay` asserted
`offer.modified == nil` for a freshly-written (2026-dated) artifact,
and `GuestFileUploadCommandTests
.testStagedUploadUsesRootPolicyAndReturnsGuestEvidence` asserted the
same for an explicit `UInt32.max` input — both passed before this fix
only because the bug made the assertion trivially true, and both were
caught by running the full host suite after the fix, not by writing
new tests. None of this has run on the emulator or the PowerBook
since the fix — the next metal session should confirm a 2026 photo's
Modified column actually draws a date rather than "--".

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
  Downloads picker (Original / Long side 1600 / Long side 1024 / Long
  side 640, default Long side 640, each naming the LONGEST edge)
  unless the ask carries the `size` token from the guest's own Size
  popup — which it now always does, preselected from the report's
  `defaultSize`. The estimated-size arithmetic the
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
