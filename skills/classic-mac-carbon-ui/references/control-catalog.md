# Native Control and UI Facility Catalog

Availability below comes from the local Universal Interfaces snapshot in `/Users/michelle/Lab/Tools/Retro68-build/toolchain/universal/CIncludes`. Recheck the target project's exact headers and runtime before implementation.

| Facility | Header evidence | CarbonLib floor | UI use | Gate or fallback |
|---|---|---:|---|---|
| Theme window background | `Appearance.h`, `SetThemeWindowBackground` | 1.0 | Apply active/inactive dialog or document backgrounds without fixed RGB grays. | Probe Appearance; fall back to documented system colors only if the app supports a pre-Appearance mode. |
| Theme tab drawing | `Appearance.h`, `DrawThemeTabPane`, `DrawThemeTab` | 1.0 | Draw native tab structure in owner-drawn composition. | Prefer `CreateTabsControl` at 1.1+ when semantic control behavior is needed. |
| Theme button drawing | `Appearance.h`, `DrawThemeButton` | 1.0 | Preserve native button states in a custom control or composite. | Supply every active/inactive/pressed/default/disabled state; prefer a native control first. |
| Bevel button | `ControlDefinitions.h`, `CreateBevelButtonControl` | 1.1 | Compact toolbar or module command with icon, text, menu, toggle, or mixed content. | Use for stable frequent actions, not as a borderless modern navigation pill. Supply labels or help for unfamiliar icons. |
| Push, checkbox, radio, and scroll controls | `ControlDefinitions.h`, `CreatePushButtonControl`, `CreateCheckBoxControl`, `CreateRadioButtonControl`, `CreateScrollBarControl` | 1.1 | Standard commands, binary/peer choices, and scrolling. | Preserve default, keyboard, focus, and disabled behavior. Do not hand-draw them. |
| Slider and little arrows | `ControlDefinitions.h`, `CreateSliderControl`, `CreateLittleArrowsControl` | 1.1 | Bounded continuous or stepwise numeric choice. | Show the value or meaningful scale; use edit plus arrows when exact input matters. |
| Disclosure triangle | `ControlDefinitions.h`, `CreateDisclosureTriangleControl` | 1.1 | Reveal advanced or subordinate content without another dialog. | Use only when disclosure preserves a stable layout and label; otherwise use a button or separate dialog. |
| Progress bar | `ControlDefinitions.h`, `CreateProgressBarControl` | 1.1 | Determinate or indeterminate operation feedback. | Call `IdleControls` as required by the control/event architecture; always pair with meaningful status and cancellation when possible. |
| Tab control | `ControlDefinitions.h`, `CreateTabsControl` | 1.1 | Switch among peer panes in a constrained window. | Avoid for workflow steps or unrelated destinations; hand-drawn tabs must still use Appearance metrics. |
| Icon control | `ControlDefinitions.h`, `CreateIconControl` | 1.1 | Display a semantic icon with native control ownership and state. | Use Icon Services for file/folder icons; provide resource fallbacks. |
| Pop-up button | `ControlDefinitions.h`, `CreatePopupButtonControl` | 1.1 | Choose one value from a compact list. | Use a list or radio buttons when simultaneous visibility materially improves comprehension. |
| Separator and group box | `ControlDefinitions.h`, `CreateSeparatorControl`, `CreateGroupBoxControl` | 1.1 | Communicate real hierarchy among related controls. | Do not box every region or use lines as decoration. Follow measured insets. |
| Placard | `ControlDefinitions.h`, `CreatePlacardControl` | 1.1 | Status strip, readout, or attached structural label. | Good for connection status at the bottom of a workspace; pair color with icon or text. |
| Image well | `ControlDefinitions.h`, `CreateImageWellControl` | 1.1 | Preview or receive a picture/icon value. | It implies content ownership or drop semantics; do not use as a decorative card. |
| Static and edit text | `ControlDefinitions.h`, `CreateStaticTextControl`, `CreateEditTextControl` | 1.1 | Labels, explanatory text, and simple text entry. | Use system fonts and measured baselines; use MLTE for rich, Unicode, or large text. |
| Data Browser | `ControlDefinitions.h`, `CreateDataBrowserControl` | 1.1 in header; listed as a 1.2 addition in the Porting Guide | Tables, lists, and hierarchies with native scrolling and selection. | Treat 1.1/1.2 wording as unresolved; for a 1.6 app gate the service and test callbacks on target. |
| Navigation Services Open/Save/Folder | `Navigation.h`, `NavGetFile`, `NavPutFile`, `NavChooseFolder` | 1.0 | Standard file and folder selection. | Supply an event UPP when application liveness must continue during the nested dialog. |
| MLTE text object | `MacTextEditor.h`, `TXNNewObject`, `TXNDraw`, `TXNSetData` | 1.0 in later header; Porting Guide describes MLTE in 1.2+ | Unicode/rich text, more than 32 KB, selection, scrolling, undo, input services, printing. | Gate MLTE independently and budget memory. Use TextEdit only for deliberately small/simple text. |
| Icon Services | `Icons.h`, `GetIconRefFromFile`, `GetIconRef` | 1.0 | Correct file, folder, application, and registered system icons. | Release `IconRef` values; provide resource icons when the lookup is unavailable or semantically inappropriate. |

## Composition Rules

- Use native controls for semantics and interaction; use Appearance drawing calls for surrounding structure and unavoidable custom elements.
- Do not use a group box, separator, placard, tab, or disclosure control as decoration. Each must communicate hierarchy or behavior.
- Keep controls fully usable at the minimum window size and 640 by 480.
- Test active and inactive windows, keyboard focus, disabled state, default button state, user accent colors, and alternate system fonts.
- Never assume an icon-only control explains itself. Use a label, help tag, menu command, or stable conventional symbol.
- Avoid forcing Data Browser into cards, modern sidebars, or touch-sized rows. Its native strengths are compact lists, columns, selection, disclosure, and scrolling.
- `CreateRelevanceBarControl` is explicitly unavailable in CarbonLib 1.x; do not use it merely because it appears in the same header as the progress bar.
- Disclosure-triangle title drawing works only on Mac OS X in the reviewed header. On classic, draw or place the label separately and use a supported orientation; `kControlDisclosureTrianglePointDefault` requires CarbonLib 1.5+.

## Callback Safety

Construct Universal Procedure Pointers with the matching `New...UPP` routine when required by the compiler/runtime. Do not cast arbitrary function pointers to callback UPP types. Keep callback storage alive for at least as long as the Toolbox object that references it, and dispose UPPs when their ownership ends.
