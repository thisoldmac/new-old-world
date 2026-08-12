<!-- now-doc-provenance: generated reviewed=false -->

# Data Browser spike

**One question:** can the guest use Carbon's Data Browser — the native
list control — for the file browser in Phase 2?

It matters because the alternative is drawing a list by hand, which is
roughly triple the work and will not feel native no matter how careful
we are.

## Why a symbol probe

An API can be declared in a header and absent from the machine's actual
CarbonLib, and then a strong import aborts launch with an opaque system
dialog — the trap that made the guest resolve Open Transport at runtime.
So before building anything on Data Browser, ask the machine in front of
us whether it exports it.

`GetSharedLibrary` + `FindSymbol` answer by NAME alone. Nothing is
called, no struct laid out, no callback installed, so the probe cannot
wedge the machine.

### A wrong turn worth recording

This spike was first written on the belief that Data Browser was
**undeclared everywhere on this machine** — that using it meant
hand-writing struct layouts and callback ABIs from documentation with no
compile-time checking.

That was false, and the cause is worth knowing: Retro68's headers carry
high MacRoman bytes and CR line endings, so **grep treats them as binary
and prints nothing at all** — not "no match", not a binary-file note,
just silence, which reads exactly like "this API does not exist."
`grep -a` finds 788 matches for `DataBrowser` in `ControlDefinitions.h`
(Universal Interfaces 3.4), and a program calling the API compiles and
links cleanly.

Before concluding a Toolbox API is missing: `grep -a`, then compile a
call to it. The compiler reads those files correctly even when grep
will not.

## What it reports

- CarbonLib's version and the Appearance Manager's, from Gestalt.
- Every Data Browser entry point Phase 2 would need: present or missing.
- Icon Services, for the icons in the list.
- The classic List Manager, which is the fallback if Data Browser is
  absent — reported so the fallback is confirmed, not assumed.

On screen, and written to `Data Browser Spike Report` on the desktop so
the answer can leave the machine as text.

## The verdict (PB1400c, 2026-07-20): use it

The control draws native and behaves. Selection, double-click and
column-header sorting all work on the real machine, from a plain
WaitNextEvent loop with no Carbon Event handlers. Phase 2's browser is
ordinary Carbon work.

What the spike taught, beyond yes:

- **A UPP is not a cast on this runtime.** MixedMode.h switches on
  RUNTIME, not architecture: TARGET_RT_MAC_CFM makes STACK_UPP_TYPE a
  UniversalProcPtr, so a C function handed straight to the Toolbox is a
  Type 3 the moment it is called. Use NewDataBrowser*UPP and check for
  NULL. The cast is right on Mach-O, which is where the belief came
  from.
- **Type-select needs keyboard FOCUS**, not just the key event.
  SetKeyboardFocus(window, browser, kControlFocusNextPart) - without it
  the list draws, selects, opens and sorts perfectly, and typing does
  nothing.
- **Icons are available both ways.** GetIconRefFromFile for a real file;
  GetIconRef (present) for a type/creator pair, which is all a listing
  off the wire carries. Only GetIconRefFromTypeInfo and the CoreGraphics
  PlotIconRefInContext are absent, and neither is needed.
- The probe missed the two UPP constructors on its first pass, reported
  20 of 20, and the thing still crashed. **A probe covers what it was
  asked about.**

## The result (PB1400c, 2026-07-20)

System 9.1.0, CarbonLib 1.6.0, Appearance 1.1.1.

- **Data Browser: 20 of 20 present.** With the headers, Phase 2 is
  ordinary Carbon code — declared, compile-checked, strongly linkable,
  because the machine really does export it.
- **Icons: `GetIconRefFromTypeInfo` is absent (-2802)**, but
  `GetIconRefFromFile`, `AcquireIconRef`, `PlotIconRef` and
  `ReleaseIconRef` are present. For the guest's own files that is the
  better call anyway. Open question, being probed in the second run: a
  listing off the WIRE has no file, only a type and creator, so it needs
  a type/creator lookup (`GetIconRef` and friends).
- **List Manager: 8 of 8 present**, so the fallback is real if it is
  ever wanted.
