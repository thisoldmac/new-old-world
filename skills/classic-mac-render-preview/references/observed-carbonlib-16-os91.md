# Observed CarbonLib 1.6 chrome on Mac OS 9.1

Use this reference whenever the target is `platinum-carbonlib`. Inspect the screenshot closest to the requested component set at original size before rendering.

## Evidence boundary

- Captured 2026-07-22 in a session-private QEMU `mac99` guest at 800x600, 8-bit color.
- Guest OS: Mac OS 9.1; startup gate: PowerPC CFM, Appearance Manager outside compatibility mode, CarbonLib 1.6 or later.
- Four native-only RetroCarbon reference applications were compiled as PEF `APPL` artifacts and launched from MacBinary files with resource forks intact.
- PEF audit confirmed CarbonLib ownership of the window, root-control, embedding-pane, event, native-control, and Icon Services entry points. IDE and Chat additionally import Textension for MLTE.
- The suite contains no application QuickDraw drawing. A hand-drawn Web surface and transfer-route canvas were rejected from the evidence set even though User Pane ownership made them valid implementation techniques; they were not clean enough to calibrate exemplar UI.
- Later File > Quit diagnostics reproduced a type-1 lifecycle failure in a changed build. The screenshots below remain valid evidence of their observed static and command-dispatch states, but no later changed build is calibration evidence until normal quit is fixed and reverified.
- These images verify the reference applications on this runtime. They calibrate previews; they do not verify a different app or every OS/theme variant in the preset range.

## Screenshot manifest

| Screenshot | Native facilities visible |
|---|---|
| [ide.png](evidence/carbonlib-16-os91/ide.png) | labeled pop-ups, connected embedding tab pane, two Data Browsers, white MLTE with vertical scrollbar, labeled progress, status placard plus Static Text, default and disabled push buttons |
| [ui-explorer.png](evidence/carbonlib-16-os91/ui-explorer.png) | labeled pop-up, bevel button, connected embedding tab pane, paired hierarchy/property Data Browsers, disclosure triangle, status placard, default push button |
| [guest-share.png](evidence/carbonlib-16-os91/guest-share.png) | group boxes, Icon Services disk/network controls, locked field, labeled progress, Data Browser, disclosure, labeled pop-up, status placard, default and secondary push buttons |
| [chat.png](evidence/carbonlib-16-os91/chat.png) | connected embedding tabs, two wrapped MLTE objects with vertical scrollbars, group box, labeled pop-up, slider, little arrows, checkbox, separator, progress, structural readout, disabled/default buttons |
| [chat-generating.png](evidence/carbonlib-16-os91/chat-generating.png) | Carbon Event command dispatch after Return: status payload changed, progress changed, Stop activated, Generate deactivated |

## Chrome observations

- The active document window has a black outer frame, ribbed Platinum title bar, compact square close/collapse/zoom widgets, a centered mixed-case title, and a resize box.
- `SetThemeWindowBackground(..., kThemeBrushModelessDialogBackgroundActive, ...)` produces the standard gray control-bearing base used by these applications. White is reserved for Data Browser, MLTE, edit, and declared document/User Pane content surfaces.
- Default push buttons have a conspicuous double black ring around a gray beveled face. Disabled buttons retain the face and border but use muted label/edge contrast.
- Tabs have sloped shoulders, a selected white face, and a connected gray pane. A tab control paints across its full bounds. The applications place the tab and an embedding User Pane under `CreateRootControl`; native pane controls attach to the User Pane with `EmbedControl`. The User Pane advertises `kControlHasSpecialBackground`, supplies `kControlUserPaneBackgroundProcTag`, and its draw callback owns MLTE.
- Data Browser headers are gray and divided into columns. The selected row/selection column is pale blue with dark text, not System 6 black reverse video. Native scrollbars carry separate arrow buttons and a draggable thumb.
- Progress indicators use a saturated blue fill with a white top highlight and gray unfilled track.
- Popup controls combine a gray text face with a narrow right-side up/down arrow area; compact widths visibly truncate long labels.
- Group boxes are thin gray outlines with a bold legend interrupting the top edge. Checkboxes, disclosures, sliders, and little arrows use compact Platinum geometry.
- MLTE is a white text surface with native scrollbars. The applications use only the vertical scrollbar where horizontal scrolling adds noise, enable view-edge wrapping for prose, set white through `TXNSetBackground`, and reset the initial selection to the start to prevent a long final line from shifting the first displayed characters offscreen.
- `CreatePlacardControl` supplies structure, not arbitrary title text. The polished status compositions use a full-width placard with a sibling Static Text label positioned inside its bounds.
- Classic Static Text mutation uses `kControlStaticTextTextTag` followed by exact-region invalidation. Changing the generic control title is insufficient evidence: it can leave the displayed status stale even while neighboring controls update.
- A Static Text label inside a special-background pane may need its back color resolved from the same Appearance brush at the owning port's actual depth. A hard-coded 32-bit color is incorrect for the 8-bit reference runtime and creates an opaque label swatch. Placard and root-window labels are different surfaces and must retain their native background.

## Renderer rules derived from the evidence

1. Start CarbonLib scenes from a standard gray application base and Platinum chrome. Reserve white for recessed or document-content surfaces.
2. Use pale blue selection with dark text for color Data Browsers.
3. Draw the default ring, disabled state, popup arrow area, progress highlight, and native scrollbars explicitly.
4. Render a full structural placard and place text inside it only through the sibling `label_mode: "adjacent-static-text"` route; report both native constructors.
5. Render full connected tab panes before their declared `pane_for` siblings; never use a floating strip.
6. Do not promote a custom QuickDraw/User Pane scene into calibration evidence merely because its ownership route is valid. Exemplar evidence must first pass the same original-size polish audit as the native-only suite.
7. Reject control-sampler composition: every visible control needs a credible application job, a clear label or surrounding hierarchy, aligned baselines, and a coherent status location.
8. Reject clipping, unexplained progress, duplicate popup labels, background seams, excessive opaque Static Text rectangles, stale dynamic text, and decorative placards.
9. Keep generated output labeled `measured-preview`; cite this calibration profile in the report.
10. Do not replace a runtime screenshot in this evidence set with a render or a build that has not passed the normal File > Quit lifecycle check on the target runtime.
