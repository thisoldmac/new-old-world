# Mac OS 8 and 9 UI/UX Guidance

Primary design authority for the Platinum additions is Apple's 1997 *Mac OS 8 Human Interface Guidelines*. It supplements rather than replaces the 1992/1995 *Macintosh Human Interface Guidelines*.

## Confirmed Principles

- Prefer Toolbox-created controls, windows, and alerts. They keep behavior consistent across appearance choices.
- Use Appearance Manager colors for custom controls.
- Treat appearance as variable and layout as durable.
- Respect user-selected accent/highlight colors and system fonts.
- Design dialog/control-panel text against Chicago metrics even though Charcoal is the default Mac OS 8 system font.
- Preserve the standard roles of document, utility, movable-modal, modal, alert, and modeless windows.
- Use control states and native feedback rather than decorative shading to communicate interaction.

## Native Vocabulary to Prefer

- push, radio, checkbox, pop-up, bevel, slider, little-arrows, disclosure, and progress controls;
- scrollable lists, edit/static text, tabs, placards, image wells, group boxes, separator lines, and headers;
- document and utility windows with proper active/inactive structure;
- contextual menus where a visible primary path also exists;
- movable modal dialogs for tasks that block the application but still benefit from repositioning and context.

## Late-1990s Polish Without Anachronism

- Use compact information density, crisp 1-bit or indexed-color icon assets, and visible grouping.
- Let the theme render bevels, highlights, shadows, and default-button emphasis.
- Use color sparingly for status and identity; never make color the only status channel.
- Use a status placard or concise text line for connection state rather than a modern translucent badge.
- Use toolbar bevel buttons only for frequent, stable commands with conventional icons.
- Keep module navigation visually subordinate to the active work area. A list, tab set, or carefully composed bevel-button rail can work; a web-style pill sidebar cannot.
- Avoid borderless cards, floating rounded rectangles, blur, alpha translucency, animated easing, SVG assumptions, and oversized whitespace.

## Measured Layout

The numeric diagrams have been transcribed into [layout-metrics.md](layout-metrics.md). Use those dimensions as resource and mockup baselines, then prefer the control's natural size or an applicable `GetThemeMetric` result where the runtime supplies one.

Do not count focus/default rings inside the base control rectangle. Do not compress the HIG spacing merely because a mockup at modern display scale appears roomy.

## Dialog and Keyboard Behavior

- Prefer movable-modal dialogs to fixed modal dialogs, and movable alerts to fixed alerts.
- Movable-modal dialogs have no close or zoom box.
- Tab moves forward through input elements; Shift-Tab moves backward.
- The default button is normally the likely action. When the likely action is destructive, make Cancel the default.
- Keep the default action invokable from Return/Enter and Cancel from Escape or Command-period where the surrounding application convention supports it.

## Review Questions

1. Is every control recognizable without relying on custom art?
2. Does each grouping communicate a task hierarchy rather than merely filling space?
3. Can the window be understood and operated at 640 by 480?
4. Are default, cancel, focus, selection, inactive, disabled, progress, error, and disconnected states visible?
5. Does keyboard navigation follow the same logical order as the visual layout?
6. Does resizing reveal useful content instead of stretching decorative areas?
7. Do all dialogs explain consequences and preserve a clear escape path?
8. Does the design still work with a different system font, accent color, or appearance setting?
