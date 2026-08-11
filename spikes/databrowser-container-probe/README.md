# Data Browser CONTAINER probe (compile-and-reason, no metal)

**One question:** is Data Browser's hierarchical/container surface —
disclosure triangles, `AddDataBrowserItems` with a real container
parent, `OpenDataBrowserContainer`/`CloseDataBrowserContainer` — safe to
build the iCloud Drive view's tree on, given that
[spikes/databrowser](../databrowser/README.md) only ever proved the
FLAT list surface (`kDataBrowserNoItem` as the parent, no disclosure
column, no container callback messages)?

This probe does not touch metal — no PowerBook, no emulator boot. It is
the "minimal compile-and-reason" probe docs/guest-ui-start-here.md and
this arc's brief ask for, one step short of the runtime symbol check
`spikes/databrowser/main.c` did with `GetSharedLibrary`+`FindSymbol` on
the real machine.

## What it checks

`probe_container.c` — compiled, not run:

```sh
$NOW_PPC_TOOLCHAIN_ROOT/bin/powerpc-apple-macos-gcc \
    -carbon -DTARGET_API_MAC_CARBON=1 -Wall -Wextra -c probe_container.c \
    -o /tmp/probe_container.o
```

Result: **compiles clean, zero warnings**, against this checkout's
Retro68 toolchain (Universal Interfaces headers, `multiversal/CIncludes`
via the toolchain's own default search path — no `-I` needed once
`-carbon -DTARGET_API_MAC_CARBON=1` are passed, matching
`retrocarbon.toolchain.cmake`'s `add_definitions`).

It declares real `New...UPP`/`Dispose...UPP` pairs for
`DataBrowserItemDataUPP` and `DataBrowserItemNotificationUPP` (same
discipline as `files_browser_view.c` — a UPP is a routine descriptor on
this CFM runtime, never a cast), and calls:

- `AddDataBrowserItems(browser, root_container, ...)` with a non-`kDataBrowserNoItem`
  container parent — the one call `spikes/databrowser/main.c` never
  made (its call always used `kDataBrowserNoItem`).
- `SetDataBrowserListViewDisclosureColumn` — the disclosure-triangle
  API. There is no separate `kDataBrowserOutlineView` view style in
  this Universal Interfaces revision (`grep -na -i outline
  ControlDefinitions.h` after `tr '\r' '\n'` finds nothing but a popup
  title flag and two comments); the hierarchical look is a LIST view
  with a disclosure column turned on, confirmed by the comment at
  `ControlDefinitions.h:2791` ("multi-column (optionally outline)
  format").
- `OpenDataBrowserContainer` / `CloseDataBrowserContainer`.
- An `item_data` callback answering `kDataBrowserItemIsContainerProperty`,
  `kDataBrowserContainerIsOpenableProperty`,
  `kDataBrowserContainerIsClosableProperty`,
  `kDataBrowserContainerIsSortableProperty`.
- An `item_notify` callback switching on `kDataBrowserContainerOpened`,
  `kDataBrowserContainerClosing`, `kDataBrowserContainerClosed` — these
  ride the SAME `DataBrowserItemNotificationUPP` the flat list already
  uses (`files_browser_view.c`, `cloud_module.c`'s `item_notify`); no
  new UPP type is needed for the tree, only new cases in the existing
  switch.

Grep note, restated because it bit this project before:
`ControlDefinitions.h` is ISO-8859 with CR line endings — `grep`
without `-a` prints nothing and reads exactly like "undeclared".
`grep -na` finds every symbol above; see the line numbers this file's
sibling investigation captured before this probe existed.

## The verdict: still UNPROVEN, treat as not viable for this arc

The compile succeeding proves the declarations exist with the expected
signatures and that a real call type-checks against the toolchain this
project ships from — nothing more. It is exactly the gap
`spikes/databrowser/README.md` names as the trap: "An API can be
declared in a header and absent from the machine's actual CarbonLib."

What tips this to "not viable, for now" rather than "go build it":

- `spikes/databrowser/main.c`'s runtime symbol probe — the only
  evidence this project has of what CarbonLib 1.6.0 actually EXPORTS on
  the PB1400c — checked 22 flat-list entry points and never asked about
  `OpenDataBrowserContainer`, `CloseDataBrowserContainer`,
  `SetDataBrowserListViewDisclosureColumn`, or
  `GetDataBrowserListViewDisclosureColumn`. Compiling against the
  header is not evidence about the four symbols that matter most here.
- The container/outline path is a materially different, less-used
  corner of Data Browser than the flat list — historically one of the
  flakier ones even on contemporary Mac OS X CarbonLib, and CarbonLib
  1.6 for Mac OS 9 is itself the reduced, backported half of that
  library.
- This task is explicitly not mine to take to metal or the emulator to
  settle ("metal verification... is not yours"; the brief calls this a
  "minimal compile-and-reason probe", not a build-and-boot one), so
  there is no path in this arc to close the gap the first bullet names.

Per this project's own rule ("never write 'works' for something in the
first two categories" — docs/README process, restated in
guest-ui-start-here.md) — compiles-clean is Level 1 (Builds), and Level
1 proves nothing about behaviour. Absent Level 2 evidence for the
container-specific entry points, the honest call is **not proven
viable**, so the drive view stays a flat list (as
`spikes/databrowser` already proved *that* surface, and
`cloud_drive_view.c`/`files_browser_view.c` exercise it
metal-verified) rather than adopting a mode this project cannot yet
back with anything past a clean compile.

**If someone later gets PB1400c or emulator time:** extend
`spikes/databrowser/main.c`'s `kDataBrowser` name table with the four
symbols above and rerun it. That is the actual next step to re-open
this — not another compile probe.

Recorded in docs/guest-ui-start-here.md's proven/disproven list and
docs/icloud.md.
