---
name: classic-mac-toolbox-ui
description: Design, review, and implement native UI and UX for normal non-Carbon classic Mac applications from System 6 through Mac OS 9 using the Macintosh Toolbox, QuickDraw, resources, standard windows, controls, menus, dialogs, Standard File, and optional non-Carbon Appearance Manager APIs. Use for 68K or classic PowerPC CFM application layouts, redraw ownership, invalidation and update regions, interaction models, monochrome or compact-screen design, System 7 UI, Platinum-era polish, dialog and control selection, file panels, keyboard behavior, or visual compatibility. Use classic-mac-carbon-ui for CarbonLib applications and classic-mac-init-platform for INITs or resident extensions.
---

# Classic Mac Toolbox UI

Design for the selected classic Macintosh era without importing Carbon, Aqua, web, or modern desktop assumptions. Select the executable profile and presentation era independently.

## Establish the UI Contract

1. Record the lowest and highest claimed system releases.
2. Record classic 68K, native PowerPC CFM, or fat application packaging.
3. Record minimum display size, color depth, system font assumptions, memory partition, and input methods.
4. Select the presentation era: System 6 monochrome, System 7 classic, or Mac OS 8/9 Appearance-aware Platinum.
5. List every optional manager or shared library and its fallback.

Read [target-eras.md](references/target-eras.md) before choosing controls or presentation. Invoke `classic-mac-toolbox-platform` when the request includes event loops, manager initialization, callbacks, libraries, builds, or artifacts.

## Prefer Native Semantic Components

Use, in order:

1. standard Toolbox windows, menus, controls, dialogs, alerts, TextEdit, and Standard File;
2. standard Appearance-aware definitions and theme drawing on an explicitly gated Mac OS 8/9 row;
3. narrowly scoped custom drawing that preserves native metrics, states, keyboard behavior, depth compatibility, and theme state;
4. raw QuickDraw decoration only when no semantic component fits.

Do not recreate toolbars, cards, pills, badges, translucency, compositing, CSS layout, Aqua controls, or touch sizing. A sidebar or module rail may be appropriate, but compose it from compact lists, labeled controls, separators, placards, and static text native to the selected era.

Read [interface-doctrine.md](references/interface-doctrine.md) for windows, menus, dialogs, controls, status, layout, and keyboard rules. Read [redraw-and-damage.md](references/redraw-and-damage.md) before implementing update handling, scrolling, TextEdit, lists, dialogs with user items, timers, dynamic status, or custom QuickDraw content.

## Apply the Era Correctly

- **System 6:** start in one-bit black and white, fit compact screens, use system definitions, and avoid facilities that require Process Manager or later managers.
- **System 7:** preserve classic behavior; gate enhanced Standard File, Apple events, Balloon Help, Drag Manager, and later facilities separately.
- **Mac OS 8/9:** use Appearance Manager only after checking it and registering deliberately as a non-Carbon Appearance client. Use theme fonts, brushes, colors, frames, and standard definitions; retain the classic fallback.

Appearance is not Carbon. Carbon APIs, opaque Toolbox ownership, Carbon Events, HIView, and Mac OS X controls remain outside this skill. Read [appearance-and-files.md](references/appearance-and-files.md) before adding Platinum custom drawing or Navigation Services.

## Protect Classic Interaction Semantics

- Prefer modeless work. Use a modal dialog only for a short, necessary, task-specific decision.
- Keep Save and Quit reachable. Make destructive operations reversible, cancelable, or explicitly cautioned.
- Preserve active/inactive, focused/unfocused, enabled/disabled, pressed, selected, and default states.
- Bind Return or Enter to the default action. Bind Escape and Command-period to Cancel where applicable.
- Duplicate color with shape, text, icon state, or position; never make color the only status signal.
- Query screen and window limits instead of assuming a large desktop or universally available zoom behavior.
- Treat user items and custom controls as full ownership of drawing, hit testing, activation, update, keyboard, disabled, and low-depth behavior.

Assign each visible rectangle to exactly one drawing owner. Ordinary commands, timers, services, and resize calculations mutate state and invalidate old and new damage; they do not draw. Reserve direct drawing for bounded tracking or immediate-feedback paths whose final state can be reconstructed by the next update event.

## Respect Cooperative Liveness

Identify every nested Toolbox loop: modal dialogs, alerts, menus, dragging, control tracking, Standard File, Navigation Services, and synchronous I/O. Use filter, idle, or action callbacks where available to perform small bounded work. Keep callbacks reentrancy-safe and do not recursively open modal UI.

Do not invent event-loop code from visual requirements. Hand the implementation to `classic-mac-toolbox-platform` and state what must remain live during tracking.

## Produce a Gated UI Handoff

For substantial design or implementation, provide:

1. target and UI-era contract;
2. window/dialog hierarchy and workflow;
3. native-component map;
4. optional capability and fallback table;
5. resource and one-bit asset plan;
6. keyboard, focus, redraw ownership, damage, update, and nested-loop behavior;
7. compact-screen, low-depth, and low-memory behavior;
8. validation matrix and unresolved target probes.

Read [verification.md](references/verification.md). Label claims **verified-document**, **verified-implementation**, **verified-target**, **probe-required**, **unsupported**, or **unresolved**. A header declaration, successful build, or plausible screenshot is not target proof.

Run `scripts/audit_redraw.py PATH...` for a function-oriented report of common update ownership, background, and callback-drawing hazards. It follows a bounded dispatcher-to-owner call map across the supplied files; unmatched update dispatch remains a manual lead, not a confirmed defect. Review every result manually because lexical call graphs cannot prove runtime ownership.
