# Start here: building guest UI

For whoever touches guest UI. Everything below cost this project real
time on the real machine, and none of it is in the
`classic-mac-carbon-ui` skill, because it is local to this codebase or
to this runtime.

Read the skill first — it is the standard. This is the errata. The
Workshop window it was originally written for now exists; to add a page
to it, read [adding-a-workshop-module.md](adding-a-workshop-module.md)
after this.

## Six rules that have each already broken something

**A UPP is not a cast.** This build is `TARGET_RT_MAC_CFM`, where
`MixedMode.h` makes a UPP a `UniversalProcPtr` — a routine descriptor.
Casting a C function to a callback UPP type and handing it to the
Toolbox is a Type 3 the first time the Toolbox calls it. Use the
matching `New...UPP` and check for NULL. The cast IS correct on Mach-O,
which is where the belief comes from, and the Apple Event Manager
tolerates it, which is how it hides for weeks. Finding:
`carbon-upp-is-not-a-cast-on-cfm`.

**Never `kWindowStandardHandlerAttribute`.** It installs HIToolbox's
standard Carbon Event handler, which expects `RunApplicationEventLoop`.
This app runs a classic `WaitNextEvent` loop, so the handler eats the
window's events: controls draw, content never draws, clicks do nothing.
On a modal that is an unrecoverable application.

**Do not migrate to Carbon Events.** The skill says it, and it applies
here: do not run two competing top-level loops in a mature
`WaitNextEvent` application. If something genuinely requires the Carbon
Event path — Data Browser type-select appears to — write it down as a
limitation rather than starting the migration inside a feature.

**Every nested loop pumps the wire.** The guest holds a live TCP
connection serviced from the main loop. `pump.h` has the callbacks:
`now_pump_modal_filter`, `now_pump_nav_event`, `now_pump_action`. A
`TrackControl` with a NULL action proc stops the connection for as long
as a finger rests on the button. `MenuSelect`, `DragWindow` and
`GrowWindow` take no callback and are documented there as unavoidable.

**Idle work must be free.** A panel that read a preferences file and
invalidated its whole window every event-loop pass starved the transfer
it was drawing — during a transfer the loop runs with no sleep. Read no
files on the idle path. `HiliteControl` redraws whatever it is passed,
so calling it every pass is a flicker loop by itself. Repaint only when
a displayed value actually changed, and invalidate the smallest
rectangle that differs.

**Anything drawn must be ASCII or MacRoman.** A UTF-8 em dash in a C
literal renders as mojibake through `DrawString`. Comments are free;
drawable strings are not.

**A manager-owned control amplifies your damage — mutate it once per
settled answer, never once per wire page.** Your own invalidations can
be perfectly bounded and the page still flashes whole: a Data Browser
repaints ITSELF on every `AddDataBrowserItems`, and a listing that
arrives as eight 16-row control frames fed straight into eight add
calls is eight full-control repaints in under a second (watched on the
PowerBook, 2026-08-02, on all three iCloud views at once — the exact
repaint scope is the CDEF's business, but the storm is yours).
Accumulate wire pages in your own store and touch the control once
when the listing settles; keystroke-time changes go through a per-row
DIFF against what the control already shows, never remove-all/add-all.
This is the recurring redraw bug's third costume — the first was
whole-pane invalidation from idle, the second unconditional
`HiliteControl` — and what the three share is one rule: the pixels a
person sees may change only when the FACTS they show changed, whether
the repaint is yours or a control's.

## Two traps that are not about drawing

**Preferences key off the binary's name.** `prefs_spec` treats
`now-guest` as the only special case, so a build deployed under any
other name finds no preferences, falls back to the defaults, and dials
`10.0.2.2:5250` — the QEMU gateway, which on real hardware never
answers. It then retries forever and looks exactly like a wedge. This
has cost two separate evenings. Either name your build `now-guest`, or
set the address in the Connection dialog on first launch, and expect
this to be the first explanation for "it hangs".

**The log opens after `conn_init`.** So a hang during connection setup
leaves no log at all, which is precisely the case you most want a log
for. If you touch startup, move `now_log_open()` above `conn_init()`.
`now-logs` sits beside the application, one file per launch, and `tail`
works from either console.

## Grep lies about the headers

Retro68's `CIncludes` are ISO-8859 with CR line endings, so `grep`
treats them as binary and prints **nothing** — which reads exactly like
"this API does not exist". That produced a confident, wrong conclusion
that Data Browser was undeclared. Always `grep -a`, then compile a call
to it. Finding: `carbon-databrowser-usable-carbonlib-16`.

## What is already proven on the PowerBook

- **Data Browser works** under CarbonLib 1.6: 22/22 symbols, draws
  native, selection, double-click and header sorting from a plain
  `WaitNextEvent` loop. Type-select does not. `spikes/databrowser` is
  the probe; `now-guest-ppc/src/files/files_browser_view.c` is a working list.
- **Icons are available**: `GetIconRefFromFile` for a real file,
  `GetIconRef` for a type/creator pair, which is all a listing off the
  wire carries. `GetIconRefFromTypeInfo` is absent.
- **Movable modals work** and are the right shape for a question — Mac
  OS reads modal ALERTS aloud, which turns every routine confirm into a
  spoken interruption. `confirm.c` is the pattern, including pumping the
  wire while the question waits.

## What is declared but NOT proven — do not assume header presence is enough

- **Data Browser CONTAINERS** (hierarchical/tree mode: disclosure
  triangles, `AddDataBrowserItems` with a real container parent,
  `OpenDataBrowserContainer`/`CloseDataBrowserContainer`,
  `SetDataBrowserListViewDisclosureColumn`,
  `kDataBrowserItemIsContainerProperty` and friends) are declared in
  this toolchain's headers and compile clean against a real call
  (`spikes/databrowser-container-probe`), but were never in the 22
  entry points `spikes/databrowser/main.c` checked with
  `GetSharedLibrary`+`FindSymbol` on the real PB1400c — that probe only
  ever exercised the FLAT list surface (`kDataBrowserNoItem` as every
  parent). Declared-and-compiles is not the same evidence as
  proven-exported, and this project has been burned by that gap before
  (`carbon-databrowser-usable-carbonlib-16` is the mirror finding: a
  header CAN lie about absence; it can equally fail to prove presence
  where it was never asked). Until someone extends that runtime probe
  with the four container-specific symbols and reruns it on metal or
  the emulator, treat hierarchical Data Browser as **not viable** here.
  The iCloud Drive browser (`cloud_drive_view.c`) stays a flat,
  replace-on-navigate list for this reason — see
  `spikes/databrowser-container-probe/README.md` and docs/icloud.md.

## How to not lose two hours

Put it on the machine before it is finished. The Workshop shell went to
the PowerBook with three empty placeholder pages, and that was the right
order: the failure mode this advice exists for is a UI that was rendered
and described but never compiled for the target, and the check that
catches it is a launch on the PowerBook, not a screenshot.

The emulator is worth a pass first — it is free and it catches drawing
bugs — but it does not settle anything. Of the two bugs the Workshop
shipped with, the emulator showed one (a wrong icon) and hid the other
(a text field that took no keystrokes there **or** on metal, but only
looked broken on metal, where someone tried to type into it).

And deploy under an honest name. A build named for what it was meant to
be, rather than what it is, cost an evening of diagnosis pointed at the
wrong half of the system.
