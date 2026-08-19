# Component contracts

Statuses describe the implementation route on the selected target. They are not visual-quality scores.

| Component | System 6 compact | System 7 classic | Platinum Toolbox | Platinum CarbonLib |
|---|---|---|---|---|
| label, separator | `native-api-route` | `native-api-route` | `native-api-route` | `native-api-route` |
| button, checkbox, radio | `native-resource-route` | `native-resource-route` | `native-resource-route` | `native-api-route` |
| edit field | `native-resource-route` | `native-resource-route` | `native-resource-route` | `native-api-route` |
| group box | `native-resource-route` | `native-resource-route` | `native-resource-route` | `native-api-route` |
| list | `native-api-route` | `native-api-route` | `native-api-route` | `native-api-route` |
| scrollbar | `native-resource-route` | `native-resource-route` | `native-resource-route` | `native-api-route` |
| tabs | `custom-required` | `custom-required` | `native-resource-route` | `native-api-route` |
| progress | `custom-required` | `custom-required` | `native-resource-route` | `native-api-route` |
| Data Browser | `unsupported` | `unsupported` | `unsupported` | `native-api-route` |
| bevel button | `unsupported` | `unsupported` | `native-resource-route` | `native-api-route` |
| placard | `unsupported` | `unsupported` | `native-resource-route` | `native-api-route` |
| pop-up, slider, little arrows | `unsupported` | `unsupported` | `native-resource-route` | `native-api-route` |
| disclosure, image well | `unsupported` | `unsupported` | `native-resource-route` | `native-api-route` |
| system icon / Icon Services | `unsupported` | `unsupported` | `native-resource-route` | `native-api-route` |
| MLTE text area | `unsupported` | `unsupported` | `unsupported` | `native-api-route` |
| QuickDraw canvas | `custom-required` | `custom-required` | `custom-required` | `custom-required` |
| generated icon glyph | `custom-required` | `custom-required` | `custom-required` | `custom-required` |

## CarbonLib primitive map

For `platinum-carbonlib`, the report names the intended native route rather than merely saying `native-api-route`:

| Scene type | CarbonLib 1.6 primitive |
|---|---|
| button, checkbox, radio | `CreatePushButtonControl`, `CreateCheckBoxControl`, `CreateRadioButtonControl` |
| field, label | `CreateEditTextControl`, `CreateStaticTextControl` |
| group, separator | `CreateGroupBoxControl`, `CreateSeparatorControl` |
| list, scrollbar | `CreateListBoxControl`, `CreateScrollBarControl` |
| tabs, progress | `CreateTabsControl` plus `CreateUserPaneControl`/`EmbedControl` for selected-pane ownership; `CreateProgressBarControl` |
| databrowser | `CreateDataBrowserControl` |
| bevel_button, placard | `CreateBevelButtonControl`; `CreatePlacardControl` plus a separate `CreateStaticTextControl` when text is visible |
| popup, slider, little_arrows | `CreatePopupButtonControl`, `CreateSliderControl`, `CreateLittleArrowsControl` |
| disclosure, image_well | `CreateDisclosureTriangleControl`, `CreateImageWellControl` |
| system_icon | `CreateIconControl` plus `GetIconRef` |
| text_area | `TXNNewObject` plus `TXNSetBackground` (MLTE) |
| quickdraw_canvas | offscreen `GWorld`, QuickDraw drawing, and bounded `CopyBits` invalidation |

The preview drawing is an original approximation of runtime output. Naming a primitive is an implementation-route contract, not proof that the target runtime rendered the PNG.

## Runtime-observed composition rules

- Data Browser headers, rows, selection, and scrollbars belong to `CreateDataBrowserControl`; do not reconstruct them with QuickDraw.
- MLTE owns its white text surface and both scrollbars. The preview may approximate the pixels, but the route remains `TXNNewObject`, `TXNSetBackground`, and Textension linkage.
- A placard is a structural gray control. Visible text is a sibling Static Text control positioned inside the placard bounds and declared with `label_mode: "adjacent-static-text"`.
- A tab pane paints across its full bounds. Render it as a connected pane and declare its selected-pane controls with `pane_for`; the polished reference places the tab CDEF and an embedding User Pane under `CreateRootControl`, then attaches the pane controls with `EmbedControl`.
- Image wells and icon controls are distinct native controls even when nested visually.
- A User Pane or QuickDraw canvas is valid only for the application's content plane. It may not paint target-native chrome or controls.

## Fallbacks

- `databrowser` may declare `fallback: "list"`.
- `tabs` may declare `fallback: "group"`.
- `progress` may declare `fallback: "thermometer"`.
- `bevel_button` may declare `fallback: "button"`.
- `placard` may declare `fallback: "group"`.
- `popup` may declare `fallback: "list"`; `slider` and `little_arrows` may fall back to `field`.
- `disclosure` may declare `fallback: "button"`; `image_well` may declare `fallback: "group"`.
- `system_icon` may declare `fallback: "icon"`; `text_area` may declare `fallback: "field"`.
- A component classified `custom-required` must declare `allow_custom: true` or an allowed fallback.
- An applied fallback is always reported as `fallback-used`; it is never upgraded to native.

## Unsupported modern patterns

Do not model these as native components: browser-style toolbars, unified title-and-toolbar chrome, modern source-list visual grammar, pill switches, badges, translucent materials, overlay scrollers, SF Symbols, live search fields, or borderless card grids. A compact native list used for module navigation is valid; it remains a list, not a modern source-list control. Decompose unsupported intent into period controls or report `unsupported`.

## Evidence basis

The Carbon/Appearance control split is grounded in the locally installed Universal Interfaces declarations, especially `ControlDefinitions.h`, plus the existing `$classic-mac-toolbox-ui` and `$classic-mac-carbon-ui` platform matrices. Any component whose exact runtime availability remains uncertain must be `probe-required`, not guessed.
