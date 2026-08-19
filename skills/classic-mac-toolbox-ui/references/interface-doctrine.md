# Interface Doctrine

## Contents

- Interaction model
- Windows and workspaces
- Menus and commands
- Controls and dialogs
- Status and custom drawing
- Layout and text

## Interaction model

- Keep the interface modeless where the user can continue useful work.
- Make modes visible, narrow, and easy to leave.
- Preserve reversibility and cancellation.
- Assume the user may activate, update, move, close, type, or select a command whenever the event loop yields.
- Show immediate visible feedback for actions and selection.

## Windows and workspaces

- Use standard document, modeless, movable-modal, modal, and alert roles.
- Prefer one coherent workspace when the product model benefits from it, but do not turn every panel into modern application chrome.
- Use native window definitions; do not assume exact title-bar, drag-region, close-box, collapse-box, zoom-box, or resize geometry.
- Query actual screen bounds and define minimum/maximum window sizes. Preserve a usable compact-screen layout.
- Follow [redraw-and-damage.md](redraw-and-damage.md): assign one owner per surface, honor update-region clipping, invalidate old and new geometry, and isolate direct tracking feedback from ordinary updates.

## Menus and commands

- Keep commands in conventional menu locations and use stable keyboard equivalents.
- Disable unavailable commands instead of allowing them to fail silently.
- Reflect selection and document state in menu enablement and marks.
- Do not use a toolbar as a substitute for a complete menu command model.

## Controls and dialogs

- Use push buttons for commands, checkboxes for independent booleans, radio groups for exclusive choices, scroll bars for scrolling, and edit text for editable content.
- Bind Return/Enter to the default action. Bind Escape and Command-period to Cancel where supported.
- Prefer movable-modal dialogs over fixed modal dialogs on later systems. Use modeless dialogs for repeated or flexible operations.
- Keep modal decisions short and necessary. Do not hide ongoing application work behind an indefinite modal loop.
- Use note, caution, and stop alerts according to severity rather than decoration.
- Treat every user item as custom code that must draw all states and survive activation, updates, low memory, and low depth.

## Status and custom drawing

- Encode status through at least two of text, shape, icon, pattern, and color.
- In one-bit mode, verify that selected, disabled, inactive, error, and connected states remain distinct.
- On Appearance systems, use theme brushes, fonts, colors, frames, and metrics. A theme brush may be a pattern, so preserve and restore pen/background state.
- Keep custom controls small and semantic. Use raw QuickDraw for application content or gaps in the standard control set, not to redraw the system.

## Layout and text

- Measure text with the active system font. Do not freeze geometry from one screenshot.
- Keep labels concise and align related controls consistently.
- Design with Chicago-compatible metrics for Mac OS 8/9 layout; Charcoal is metric-compatible but not pixel-identical.
- Check international expansion, MacRoman/script handling, keyboard-only use, and focus visibility.
- Create 1-bit assets first, then add color variants that preserve silhouette and meaning.
