# Data Browser spike

**One question:** can the guest use Carbon's Data Browser — the native
list control — for the file browser in Phase 2?

It matters because the alternative is drawing a list by hand, which is
roughly triple the work and will not feel native no matter how careful
we are.

## Why this is a symbol probe and not a working list

There are **no Data Browser declarations anywhere on this machine** —
not in Retro68's headers, not in the Apple Universal Interfaces, not in
the MPW Golden Master. Those are Universal Interfaces 3.x; Data Browser
arrived with Appearance Manager 1.1 and was declared in later SDKs.

So using it at all means hand-declaring the ABI — struct layouts,
callback signatures, dozens of constants — from documentation, with no
compile-time checking, on a machine where a wrong struct layout is a
crash rather than an error. That is a real cost, and it is only worth
paying if the symbols are actually there.

`GetSharedLibrary` + `FindSymbol` answer that by NAME alone. Nothing is
called, no struct is laid out, no callback is installed. The spike
cannot crash the machine, and it either opens the expensive path or
closes it.

## What it reports

- CarbonLib's version and the Appearance Manager's, from Gestalt.
- Every Data Browser entry point Phase 2 would need: present or missing.
- Icon Services, for the icons in the list.
- The classic List Manager, which is the fallback if Data Browser is
  absent — reported so the fallback is confirmed, not assumed.

On screen, and written to `Data Browser Spike Report` on the desktop so
the answer can leave the machine as text.

## Reading the result

- **All Data Browser symbols present** — the path is open. Next
  question is whether hand-declaring the ABI is worth it, which is a
  judgement call, not a probe.
- **Any missing** — the path is closed on this machine, and Phase 2
  uses the List Manager. Cheaper to know now than after the ABI work.
