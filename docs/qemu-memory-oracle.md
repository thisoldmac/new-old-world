<!-- now-doc-provenance: generated reviewed=false -->

# QEMU memory oracle

The QEMU memory oracle is a development microscope for questions such as
"which live Mac OS object backs this blank list?" It is deliberately not a
NOW capability, a Mirror data source, or an acceptance driver. It reads an
explicitly identified development VM while its CPU is paused, decodes public
classic Mac records, resumes the VM, and writes analysis JSON.

The production direction remains:

```
Mac OS events and state -> NOW Extension/application -> state engine -> Mirror
```

The oracle sits outside that line. A fact learned through QEMU has to be
implemented using Mac OS state or events that also exist on a PowerBook. The
NOW Host, state engine, Mirror renderer, guest application, and NOW Extension
do not import this tool. QEMU memory cannot satisfy a Mirror gate and QMP is
never used to mutate the guest.

## Capture one coherent application context

`tools/qemu-oracle` requires both the QMP socket and a separately produced
identity file. The identity binds the socket to the expected VM name, NOW
guest, connection session, and guest build; the oracle refuses a mismatch.
It then samples low-memory `CurApName` while QEMU is stopped and retries until
the requested application's A5 context is current.

```sh
tools/qemu-oracle snapshot \
  --qmp /explicit/path/qmp.sock \
  --identity /explicit/path/oracle-identity.json \
  --app 'Date & Time' \
  --out /tmp/date-time-memory.json
```

The snapshot currently records the current A5 and stack base, Window Manager
list, Window/Dialog records, DITL items, control chains, and bounded prefixes
of control-owned private data. Addresses remain provenance, not durable
identity. Captures can be compared without reconnecting to QEMU:

```sh
tools/qemu-oracle diff before.json after.json
```

This first slice answers object-shape and before/after questions. Call-site
breakpoints, write watches, and lifecycle traces are a later oracle adapter;
they must retain the same explicit identity, pause/read-only posture, and
production isolation.

## First live result: Set Time Zone

On 2026-08-04 the oracle sampled the front `Date & Time` context while the
guest showed the Set Time Zone dialog. It found the titled Dialog Manager
window, its eight DITL items, nine controls, and the visible list control at
`0x1e6ad2b4`. A separate read of the NOW Extension's `NWpt` table showed the
semantic request naming that exact window and control and a completed
`UnsupportedCustom` response.

That corrects the earlier hypothesis that the extension had returned the
city/country cells and the bridge dropped them. The new bridge and renderer
support for `listCells` is still valid, but this live control never reached
that producer: `ext/src/now_semantic.c` rejects a list box when its LDEF is
nonzero. The guest framebuffer proves that Mac OS has the rows; the Mirror's
hatched list proves the structured producer does not yet expose them.

The first production patch now follows that bounded route: the extension
classifies with public `kControlKindTag`, requires an Apple list-box kind, and
then asks for `kControlListBoxListHandleTag` without treating a nonzero drawing
LDEF as refusal. It contains no Date & Time resource-ID special case and pipes
no guest pixels. This is cross-built and native-tested, but remains a
hypothesis until the rebuilt INIT is cold-loaded and the same live control
returns its rows.

## Cold-load correction: the single cell can lag the front application

The v2 INIT and matching application were cold-loaded on 2026-08-04 and the
same modal was driven through a freshly built Mirror. Set Time Zone remained
red: the list region still contained only unavailable bitmap geometry, and
Sherlock's newest settled P3 generation likewise contained a final CopyBits
blit without structured drawing above it. Moving CopyBits placeholders behind
structured ops is therefore a valid renderer rule, but it cannot manufacture
the P2 controls and rows those surfaces still lack.

A coherent physical-memory sample found the live `NWpt` table at physical
`0x00935c10` (table addresses are evidence for this VM only). Two samples
showed the request generation advancing from `0x1fa` to `0x223` while naming
the same Finder `System Folder` window/control tuple. The last completed P2
response remained at request generation `0x1de`, status
`UnsupportedCustom`, for a Date & Time base-window control. At the same time,
the host state-engine snapshot identified Date & Time and Set Time Zone as the
fresh front process/window. This does **not** prove what
`kControlKindTag` returns for the Set Time Zone list, because the sampled cell
never completed that exact request. It does prove that the one-cell producer
can spend repeated front-window scenes waiting on a background-process target
and leave the live modal without a current semantic answer.

The samples do not distinguish an unsatisfied front-control request from a
front-control refusal already cached in the application, so they do not by
themselves justify a scheduler rewrite. They do identify the next bounded
classification experiment: a capability probe using the public
`kControlListBoxListHandleTag` when a custom signature still exposes a
standard List Manager handle. That fallback is now implemented as an exact
live-control request. An Apple-owned non-list refuses before the probe;
success requires `noErr`, the exact handle size, and a non-null handle; failure
remains explicit custom/unsupported. The flat INIT cross-build passes, its
source guard was mutation-watched, and the file is staged on the development
overlay, but it is not running until a clean cold reboot. No QEMU address,
Date & Time resource ID, or private control-data offset entered the product
path.

**Later cold-load result.** The extension at `cad8e57` was cold-loaded with
fingerprint `67d5ef434db7def800d4ba35690c43b2434ccf32`. The public List Manager
probe still did not surface Set Time Zone rows in the Mirror. In that VM, the
oracle located the list control at `0x1e621e2c` and its non-null data handle at
`0x1e621a68`; those addresses are disposable evidence, not product inputs.
The resident request cell repeatedly named a Finder target while its completed
response remained an older Set Time Zone `UnsupportedCustom` result. That led
to a front-process-first/pending-lease scheduler patch (`891c74a`), which is
built as a checkpoint but not yet cold-loaded or UX-verified. The useful
conclusion is narrower than an application special case: public control data
exists, but the single resident cell can starve the front surface before its
class-specific producer gets a chance to answer.

## First cross-application inventory

The same live run captured three surfaces before any further extension patch.
This matters because `UnsupportedCustom` is currently an overloaded answer:
the semantic classifier asks every control whether it is a standard LDEF-0
list box, so an ordinary non-list control and a genuinely private custom
control can receive the same status.

| Surface | Guest object inventory | Mirror failure | Producer class |
|---|---|---|---|
| Date & Time base panel | one Dialog Manager window, 20 DITL items, 21 controls | date and time values, time-zone explanation, time-server status, clock status, and help content absent; standard buttons and choices largely survive | DITL plus Appearance/Control Manager values and text |
| Set Time Zone | one Dialog Manager window, 8 DITL items, 9 controls | city/country rows absent | List Manager data behind a nonzero drawing LDEF |
| Sherlock 2 | one custom-kind window, 35 controls | channel strip, search-site rows, result panes, labels, and icons largely absent; only structural shells survive | mixed standard controls, edit field, list-like controls, application-defined controls, and deferred assets |
| Key Caps | two windows, zero controls | keyboard face absent; only a content-unavailable shell appears | application QuickDraw, not a missing Control Manager semantic |

The first extension batch is therefore class-based. It inventories public Mac
OS control kinds/data tags across both Date & Time and Sherlock, retains an
explicit unsupported record for private structures, and expands the compact
class cache so all 35 Sherlock controls can settle. It does not turn each
application or resource ID into a new semantic operation. Key Caps instead
uses the existing meaningful whole-content unavailable placeholder because its
two windows expose no controls; pixel/content transport remains out of scope.

The paired artifacts for this run are under
`/private/tmp/now-u7-extension-only/`: `f214af2-*-mirror.jpeg`,
`mirror-shots/f214af2-*-guest.png`, and `f214af2-*-memory.json`. They are
development evidence tied to guest build `b684adc2f96a`, session
`a6358eaa-d75e-448e-9777-364388096809`, and VM
`NOW U8 f214af2 broad sweep`; they are not checked-in fixtures.

## Second use: settling a layout question the code could not ask itself

**2026-08-06.** An alert's message text was missing from the wire, and
the first repair was header arithmetic — derive the item's length from
the block header below its data, the documented classic layout. It
returned **nothing**, silently: no error, no exception, nothing to
debug. An assumption about a structure fails by producing an answer.

The oracle settled it, on a **stopped VM**, in one run. This heap's
block header is not the 24-bit-era layout:

- The longword below the data holds a **zone-relative offset**, not the
  master pointer. Demonstrated rather than inferred: two different items
  differed from their handles by the *same* base.
- The tag byte's size-correction nibble reads **zero** while the
  physical block overshoots the string by **eight bytes** — so the
  arithmetic would have appended eight bytes of heap slop to every
  alert, which is a wrong answer that looks right in most captures and
  would have been much more expensive than the empty one.

The repair was to stop deriving and ask the Memory Manager:
`GetHandleSize`, behind `GetDialogItemText`. The seam and the reason are
in `now-guest-ppc/src/scene/dialog_text.h`; the raw bytes are in
[open-issues.md](open-issues.md) under the alert entry.

**This is the oracle's second distinct job, and worth naming as a
category.** The first use above explains *what an application contains*
when the Mirror renders it wrong. This one answers *whether our own
assumption about a structure is true* — and nothing that parses a block
using the layout can answer that, because it has no way to disagree with
itself. Reach for the oracle whenever a derivation over a guest
structure returns empty or implausible, not only when a surface renders
badly. It is cheap and it does not need the VM running.

## Acceptance boundary

Oracle output can explain a red row and guide a metal-compatible producer. It
cannot turn one green. A green UX row still requires native keyboard/mouse
input into the Mirror, authoritative guest pixels, Mirror pixels, the shared
state-engine snapshot, operation settlement, and correlated logs. The worst
member of that evidence set is the verdict.
