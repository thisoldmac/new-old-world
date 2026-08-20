---
name: classic-mac-carbon-ui
description: Design, review, and implement polished PowerPC application UI for classic Mac OS 8.6 through 9.2.2 using CarbonLib, the Appearance Manager, Toolbox controls, QuickDraw, resources, and Retro68. Use when planning windows, dialogs, navigation, controls, icons, text, redraw ownership, invalidation, update regions, event handling, or compatibility gates for a classic Mac application, especially when an API must be checked against a CarbonLib or OS floor.
---

# Classic Mac Carbon UI

Build interfaces that look and behave native to the Platinum era while remaining honest about the target machine. Treat Mac OS version, CarbonLib version, backing shared libraries, memory, color depth, and screen size as separate capability axes.

## Start With the Target Contract

1. Record the minimum and maximum Mac OS releases.
2. Record the minimum CarbonLib version and whether the application may install it.
3. Record CPU architecture, compiler/toolchain, minimum screen size, color-depth assumptions, and memory budget.
4. Separate compile-time SDK presence from runtime availability.
5. State whether the design must survive disabled systemwide Platinum appearance, alternate system fonts, low color depth, and 640 by 480 displays.

Read [platform-matrix.md](references/platform-matrix.md) before choosing APIs. Read [libraries.md](references/libraries.md) and [runtime-gates.md](references/runtime-gates.md) before calling an optional service. Read [control-catalog.md](references/control-catalog.md) before inventing or hand-drawing a control. Read [redraw-and-damage.md](references/redraw-and-damage.md) before implementing windows, tabs, custom panes, scrolling, MLTE, Data Browser, dynamic status, or any other changing surface.

## Gate Every Non-Baseline Facility

For each proposed API or subsystem, report:

- header and declaration;
- minimum CarbonLib version;
- backing classic shared library or Gestalt selector, when applicable;
- runtime test;
- behavior when unavailable;
- evidence status: verified, provisional, or unresolved.

Do not infer runtime availability from successful compilation, linkage, or a non-null imported function pointer. CarbonLib 1.6 lazily loads several backing libraries and may expose non-null glue even when the service is absent. Prefer Gestalt; use `GetSharedLibrary` when no selector exists.

## Choose the Highest Native Primitive That Fits

Prefer, in order:

1. standard Toolbox or Appearance Manager controls;
2. system drawing primitives such as `DrawThemeButton` for owner-drawn composition;
3. a small custom control that preserves native metrics, states, keyboard behavior, and appearance colors;
4. raw QuickDraw decoration only when the platform has no semantic control.

Use resource-defined menus, icons, dialogs, strings, and control metadata where that improves localization and editability. Do not recreate Aqua, Cocoa, CSS, transparency, compositing, or modern vector-icon behavior on a QuickDraw/Platinum target.

## Establish Redraw Ownership

Classify each window as standard Carbon draw-content ownership or deliberate manual update ownership. Do not mix the two. Assign every visible rectangle to the Window Manager, Control Manager, a manager-owned content object, a custom control callback, or application QuickDraw content.

Ordinary commands, timers, services, and bounds handlers mutate state and invalidate old and new damage; they do not draw. Direct drawing is reserved for documented immediate-feedback paths such as live tracking and scrolling. The next ordinary update must reproduce the same display entirely from model state.

Use window-qualified Carbon invalidation APIs. Do not use classic `InvalRect`, `InvalRgn`, `ValidRect`, or `ValidRgn` in Carbon source.

For a tabbed control-heavy window, the normal base is the active/inactive
modeless-dialog Appearance brush, not an unconditional white erase. White is
for a manager-owned content well such as MLTE, edit text, or Data Browser. A
tab must be a real `CreateTabsControl` with a full connected pane and an
embedded content hierarchy, never a floating strip over unrelated siblings.

## Apply Platinum-Era UX Rules

Use [classic-hig.md](references/classic-hig.md) and [layout-metrics.md](references/layout-metrics.md) for the researched UI rules and exact Mac OS 8 measurements.

- Use native controls, windows, and alerts whenever possible.
- Use Appearance Manager brushes, fonts, and colors rather than fixed grays.
- Design against system-font metrics, not a single raster-font screenshot.
- Make active, inactive, focused, default, disabled, pressed, and selected states legible.
- Preserve keyboard navigation, menu command equivalents, cancel/default behavior, and visible feedback.
- Prefer one clear primary workspace over many unrelated utility windows when the product model calls for it, but keep classic window and dialog roles intact.
- For a workspace sidebar, use a compact selectable list or labeled bevel-button rail; use a placard and static text for at-a-glance connection state. Do not import web navigation, cards, pills, badges, or touch sizing.

## Protect Cooperative Liveness

Assume classic Mac OS is cooperatively scheduled. Identify every nested Toolbox loop: modal dialogs, Navigation Services dialogs, menu tracking, window dragging, control tracking, alerts, and synchronous file or network work.

Where an API provides an idle/filter/action callback, use it to pump bounded application work. Keep callbacks reentrancy-safe. Never open another modal from code pumped inside a modal. Document unavoidable tracking stalls and keep the modern peer bounded with deadlines when the classic peer can be starved.

Read [events-and-liveness.md](references/events-and-liveness.md) when a feature opens a dialog, tracks a control, performs I/O, or maintains a host connection.

## Build a Real Classic Application Artifact

Use [resources-and-assets.md](references/resources-and-assets.md) for the CFM/Rez application envelope, Finder identity, memory sizing, menus, strings, dialogs, and icon families. Treat the resource fork as application structure, not an asset dump.

Keep creator/type codes, `BNDL`/`FREF`, icon IDs, `vers`, and `SIZE` mutually consistent. Include `acceptSuspendResumeEvents`; test foreground/background activation on the actual CarbonLib runtime.

## Produce a Gated Design Handoff

Return these sections for substantial UI work:

1. target contract;
2. window and module hierarchy;
3. native-control map;
4. capability and fallback table;
5. resource plan;
6. event, redraw-ownership, damage, and nested-loop plan;
7. low-resolution and low-memory behavior;
8. verification matrix on emulator and representative hardware.

Follow [verification.md](references/verification.md). If a claim is not yet supported by a primary Apple document, a Universal Interfaces availability block, or an observed target run, label it provisional. Consult [research-ledger.md](references/research-ledger.md) and [sources.md](references/sources.md) for provenance and residual caveats.

Use `scripts/extract_availability.py` to inventory availability annotations instead of scanning headers by eye. Treat its output as extracted declaration evidence, not a runtime guarantee.

Run `scripts/audit_source.py PATH...` for a quick report of common classic-target hazards. Review every result manually; it is a lexical audit, not a compiler or runtime test.
