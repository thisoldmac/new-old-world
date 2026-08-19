# Verification Matrix

Header evidence defines what may be attempted. Only an observed run validates the product contract.

## Required Systems

| Target | Minimum run |
|---|---|
| Mac OS 8.6 with CarbonLib 1.6 | launch, all windows and modules, menus, dialogs, files, connection lifecycle, low-memory, and 640-by-480 checks |
| Mac OS 9.0.4 with CarbonLib 1.6 | same, plus sleep and wake and Keychain-dependent behavior if used |
| Mac OS 9.1 with CarbonLib 1.6 | smoke and regression pass |
| Mac OS 9.2.2 with CarbonLib 1.6 | full blessed regression pass |

Use emulation for repeatable matrix coverage and representative PowerPC hardware for timing, font, display, file-system, and cooperative-liveness confidence. Record emulator or model, ROM and system image, CarbonLib version, RAM, display mode, and build identifier.

## Display and Layout

- 640 by 480 minimum screen and one larger representative mode;
- 1-bit or grayscale where available, 8-bit, 16-bit, and 32-bit color;
- default and alternate system font, accent, and highlight settings;
- active and inactive windows; selected and unselected rows; enabled, disabled, pressed, default, focus, and disclosure states;
- minimum window size, resizing, WindowShade or collapse, Control Strip and menu-bar constraints, and multiple-display origin if supported;
- every string at maximum realistic or localized length with no clipping.

## Input and Commands

- mouse, Tab, Shift-Tab, Return or Enter, Escape or Command-period, arrows, space, and menu command equivalents;
- menu state follows the front window and module and changes immediately after selection or state mutation;
- contextual and drag paths have visible menu or button equivalents;
- double-click and default action are consistent and never destructive by surprise.

## Capability and Failure Tests

- launch below the OS or CarbonLib floor produces one correct alert and a clean exit;
- each optional service can be forced absent or failed without a crash;
- low-memory launch, allocation failure, disk-full, read-only volume, unavailable host, dropped connection, retry, cancel, and peer timeout;
- suspend and resume, foreground and background, sleep and wake, and forced inactive-window redraw;
- modal dialog, Navigation dialog, menu tracking, long scroll or drag, and window move while the host connection is active.

## Redraw Torture Pass

- cover and uncover each window in narrow strips with another window;
- move it partly offscreen and back, then force an inactive/background update;
- resize rapidly in both directions and verify that moved or hidden content leaves no ghosts;
- switch tabs repeatedly after placing keyboard focus, selection, or a caret in the departing pane;
- exercise line, page, and thumb scrolling while holding the mouse down;
- type, select, scroll, activate, and deactivate every TextEdit or MLTE surface;
- mutate status, controls, rows, or content while the affected region is obscured;
- allow model changes during menus, dialogs, tracking, and other nested loops, then close the loop;
- compare the resulting display with a forced full invalidation from the same model state.

Reject flicker, stale pixels, duplicate control chrome, hidden-pane focus or caret, wrong active/inactive states, white base-window flashes, and any display state that exists only because a tracking callback drew it directly.

## Evidence to Capture

For each system, retain a diagnostic line containing OS, CarbonLib, probed service versions and bits, RAM partition and free memory, screen size and depth, and build ID. Capture screenshots for the shell and each state family, plus a result table with pass, fail, not applicable, and untested. Never silently convert untested into supported.
