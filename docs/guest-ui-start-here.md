# Start here: building guest UI

For whoever builds the workshop window. Everything below cost this
project real time on the real machine, and none of it is in the
`classic-mac-carbon-ui` skill, because it is local to this codebase or
to this runtime.

Read the skill first — it is the standard. This is the errata.

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
  the probe; `guest/src/host_browser.c` is a working list.
- **Icons are available**: `GetIconRefFromFile` for a real file,
  `GetIconRef` for a type/creator pair, which is all a listing off the
  wire carries. `GetIconRefFromTypeInfo` is absent.
- **Movable modals work** and are the right shape for a question — Mac
  OS reads modal ALERTS aloud, which turns every routine confirm into a
  spoken interruption. `confirm.c` is the pattern, including pumping the
  wire while the question waits.

## How to not lose two hours

Put the shell on the machine before it does anything. One window, the
sidebar, no modules. Deploy it, launch it, look at it. The failure mode
this advice exists for is a UI that was rendered and described but never
compiled for the target — the check that catches it is a build on the
PowerBook, not a screenshot.

And deploy under an honest name. A build named for what it was meant to
be, rather than what it is, cost an evening of diagnosis pointed at the
wrong half of the system.
