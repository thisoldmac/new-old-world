# Scene specification

The renderer accepts one JSON object.

```json
{
  "target": "system6-compact",
  "application_basis": "design-concept",
  "presentation": {"chrome": "target-native"},
  "screen": {"width": 512, "height": 342, "depth": 1},
  "application": "Disk Catalog",
  "window": {"x": 42, "y": 42, "width": 428, "height": 250, "title": "Disk Catalog", "active": true},
  "components": [
    {"id": "prompt", "type": "label", "x": 22, "y": 38, "text": "Choose a disk:"},
    {"id": "name", "type": "field", "x": 22, "y": 56, "width": 250, "height": 20, "text": "Archive"},
    {"id": "scan", "type": "button", "x": 298, "y": 202, "width": 90, "height": 22, "text": "Scan", "default": true}
  ],
  "assets": []
}
```

Component coordinates are relative to the window content area. Supported types are `label`, `separator`, `button`, `checkbox`, `radio`, `field`, `group`, `list`, `scrollbar`, `tabs`, `progress`, `databrowser`, `bevel_button`, `placard`, `popup`, `slider`, `little_arrows`, `disclosure`, `image_well`, `system_icon`, `text_area`, `quickdraw_canvas`, and `icon`.

`presentation.chrome` defaults to `target-native`. `classic-monochrome` is available only as an explicit visual-era override and is reported as such when it differs from the target preset.

`application_basis` defaults to `design-concept` and is always recorded in the report. Use `verified-implementation` only for a state grounded in the named application's observed implementation, `evidence-backed-prototype` for a proposed UI over proven underlying seams, and `design-concept` for an unimplemented product direction.

Common fields: `id`, `type`, `x`, `y`, `width`, `height`, `text`, `disabled`, `fallback`, and `allow_custom`.

Type-specific fields:

- checkbox/radio: `checked`.
- list/databrowser: `items` and optional zero-based `selected`.
- databrowser: optional `columns`, each either a title string or `{ "title": "Name", "width": 220 }`; rows may be strings, arrays, or objects keyed by column title.
- tabs: `items`, optional zero-based `selected`, and `pane_for`, a nonempty array of component IDs that logically occupy the selected pane. For `platinum-carbonlib`, the tab must be at least 60 pixels high, precede its pane components in the scene, and geometrically contain them; detached strips are rejected.
- progress: numeric `value` from 0 through 100.
- placard: the native control is structural and does not draw arbitrary title text. If `text` is present on `platinum-carbonlib`, set `label_mode` to `adjacent-static-text`; the renderer places the sibling Static Text inside the full placard bounds and the report records both constructors.
- bevel_button: `text`; use it for a frequent stable command or module action, not as a modern pill.
- popup: `items`, optional zero-based `selected`, and optional `text` override.
- slider/little_arrows: integer `min`, `max`, and `value`; slider may add `ticks`.
- disclosure: `text` and boolean `open`.
- image_well: `symbol` and optional `caption`.
- system_icon: `symbol`; represents `CreateIconControl`/Icon Services, while `icon` remains a custom original glyph.
- text_area: `lines`, optional `line_numbers`, and optional zero-based `selected_line`; represents an MLTE-owned text object.
- quickdraw_canvas: `mode` is one of `screen-delta`, `web-document`, `transfer-route`, `charts`, or `media-frame`; always requires `allow_custom: true` and represents an application-owned QuickDraw/GWorld plane inside native Carbon chrome. `web-document` may set `media_label`; the label must describe the real presentation route (for example, a link that opens a separate Movie Controller window).
- placard may set `status_color` to `accent`, `success`, `warning`, `danger`, or `purple`; color supplements an adjacent Static Text label and never carries status alone.
- icon: `symbol` is one of `document`, `folder`, `disk`, or `warning`.
- button: `default`.

Unknown keys are retained in the normalized scene but do not alter drawing. Unknown component types are errors.
