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

The next production question is therefore bounded: determine whether the
control's public `kControlListBoxListHandleTag` yields a valid List Manager
record even with a custom drawing LDEF, then widen the NOW Extension's generic
read-only list contract if the public record invariants hold. Do not add a
Date & Time resource-ID special case and do not pipe the guest pixels.

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

The first extension batch must therefore be class-based. It should inventory
and support public Mac OS control kinds/data tags across both Date & Time and
Sherlock, retaining an explicit unsupported record for private structures. It
must not turn each application or resource ID into a new semantic operation.
Key Caps instead needs a meaningful structured unavailable placeholder while
pixel/content transport remains out of scope.

The paired artifacts for this run are under
`/private/tmp/now-u7-extension-only/`: `f214af2-*-mirror.jpeg`,
`mirror-shots/f214af2-*-guest.png`, and `f214af2-*-memory.json`. They are
development evidence tied to guest build `b684adc2f96a`, session
`a6358eaa-d75e-448e-9777-364388096809`, and VM
`NOW U8 f214af2 broad sweep`; they are not checked-in fixtures.

## Acceptance boundary

Oracle output can explain a red row and guide a metal-compatible producer. It
cannot turn one green. A green UX row still requires native keyboard/mouse
input into the Mirror, authoritative guest pixels, Mirror pixels, the shared
state-engine snapshot, operation settlement, and correlated logs. The worst
member of that evidence set is the verdict.
