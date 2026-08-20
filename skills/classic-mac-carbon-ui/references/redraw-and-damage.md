# CarbonLib Redraw and Damage Contract

Use this contract for CarbonLib 1.x applications on Mac OS 8.6 through 9.2.2. Classify the event model and the owner of every visible surface before writing drawing code.

## Contents

- Ownership matrix
- Mutation, damage, and paint
- Carbon Event skeletons
- Controls, panes, and tabs
- Background and QuickDraw state
- Manager-specific rules
- Review questions

## Ownership Matrix

| Surface or event path | Owner and required behavior |
|---|---|
| Standard window handler plus `kEventWindowDrawContent` | The standard handler has already selected the port, called `BeginUpdate`, and drawn intersecting system controls. Draw only application-owned content. Do not call `BeginUpdate`, `EndUpdate`, `DrawControls`, or `UpdateControls`; return `noErr` after handling. |
| Deliberate `kEventWindowUpdate` override | The application owns port selection, `BeginUpdate`/`EndUpdate`, control updating, and custom content. Do not also run the standard draw-content path. |
| Standard control | Change state with Control Manager APIs. Let the standard handler draw activation, enablement, value, tracking, and bounds changes. Use `Draw1Control` only for an intentional immediate single-control refresh. |
| User Pane or custom control | Draw only from its draw callback or `kEventControlDraw` handler. Own activation, focus, disabled state, hit testing, tracking, and background behavior required by that custom surface. |
| Data Browser | Supply data through callbacks and mutate it with `AddDataBrowserItems`, `RemoveDataBrowserItems`, or `UpdateDataBrowserItems`. Draw item content only for a property declared as custom type. |
| MLTE-only window | `TXNUpdate` may own `BeginUpdate` and `EndUpdate`. |
| Composite window containing MLTE | The enclosing window update owns `BeginUpdate`/`EndUpdate`; call `TXNDraw(object, NULL)`. Use `TXNForceUpdate` to request a frame update. Do not use `TXNUpdate`. |
| Direct QuickDraw content | The application owns background, clipping, QuickDraw state, invalidation, active/inactive appearance, and complete reconstruction from model state. |
| Tracking or live scrolling | Immediate direct drawing is allowed when tracking feedback must remain live. Clip to the owned content, use `ScrollWindowRect` or `ScrollWindowRegion` when useful, and leave model state that a later update event reproduces exactly. |

Do not recommend `HIViewSetNeedsDisplay` for the classic CarbonLib 1.6 path. It is not present in the selected classic-target Universal Interfaces.

## Mutation, Damage, and Paint

Keep ordinary state changes in this order:

1. mutate model state;
2. recompute layout if geometry changed;
3. invalidate every damaged region with `InvalWindowRect` or `InvalWindowRgn`;
4. return to the event loop;
5. paint current model state from the selected draw or update handler.

Invalidation requests eventual drawing; it does not paint immediately. Multiple invalidations may be coalesced.

For an element that moves, resizes, hides, or changes content ownership, invalidate both its old bounds and its new bounds. The damage is their union, not merely the final frame. Switching tabs must invalidate the departing pane as well as the arriving pane.

Prefer component-level damage. Full-window invalidation is acceptable for a small initial implementation or a genuinely global appearance change, but it is not the default response to a local status, selection, caret, or row change.

### Manager-Owned Controls Amplify Mutation Damage

A manager-owned control repaints on its own schedule when mutated. `AddDataBrowserItems`, `RemoveDataBrowserItems`, `SetControlTitle`, `HiliteControl`, and `SetControlValue` draw immediately or invalidate the control themselves, outside the caller's invalidation discipline — so application damage can be perfectly bounded while the display still flashes, because the mutation cadence, not the invalidation, is what the caller controls.

- **Mutate once per settled answer.** When one model change arrives in several parts — paged listings, streamed chunks, incremental transfers — accumulate the parts in model state and mutate the control once when the answer settles. One mutation per arriving part multiplies whole-control repaints by the part count.
- **Diff per keystroke.** Incremental filtering adds and removes only the rows whose membership changed. Remove-all/add-all per keystroke repaints the entire control per character.
- **Compare before re-asserting.** `HiliteControl` and `SetControlTitle` redraw even when the new state equals the old. On idle, timer, or polling paths, keep a last-asserted copy and call only on change.
- **A live-progress fill is a designed exception.** Rows appearing while a genuinely long scan proceeds are legitimate feedback; the arrival cadence must then be the scan's own pace, not a transport's framing.

Evidence status: observed on a CarbonLib 1.6 hardware run and measured on an emulated CarbonLib 1.6 target (2026-08-02, instrumented item-data counters plus update-region sampling) — a Data Browser mutation draws nothing synchronously; `AddDataBrowserItems` and `RemoveDataBrowserItems` invalidate the control's entire list content area regardless of which rows changed, and damage coalesces per event-loop pass, so N mutations across N passes repaint the visible rows N times while N mutations within one pass repaint them once. The scope may still vary by CarbonLib version and control state; the amplification rule does not depend on it, only on the pass count the caller chooses. See the research ledger for the measurement.

## Carbon Event Skeletons

With a standard window handler:

```c
case kEventWindowDrawContent:
    DrawApplicationContent(window);
    return noErr;

case kEventWindowBoundsChanged:
    RecomputeLayoutAndSetControlBounds(window);
    InvalidateChangedApplicationRegions(window);
    return noErr;
```

`DrawApplicationContent` must not open a second update cycle or redraw standard controls.

Only when deliberately replacing standard update ownership:

```c
SetPortWindowPort(window);
GetWindowRegion(window, kWindowUpdateRgn, updateRgn);
BeginUpdate(window);
UpdateControls(window, updateRgn);
DrawApplicationContent(window);
EndUpdate(window);
```

Choose one path for a window. Do not mix them.

## Controls, Panes, and Tabs

Create a root control and preserve the embedding hierarchy. Embed child controls in their containing User Pane or group so visibility, activation, movement, and redraw propagate through the hierarchy.

Implement tabs as a native tab control associated with real panes:

1. read the tab control value after `kEventControlHit`;
2. clear keyboard focus before hiding a pane that may own it;
3. hide unselected pane controls with `SetControlVisibility(pane, false, true)`;
4. show the selected pane with `SetControlVisibility(pane, true, true)`;
5. redraw the tab control only if the selected-state display did not update automatically.

Do not paint a tab strip over unrelated sibling content or keep controls from hidden panes visible and independently active.

### Special-background panes and Static Text

Use a User Pane with `kControlHasSpecialBackground` and a
`kControlUserPaneBackgroundProcTag` callback when embedded controls need a
selected-pane brush. The callback receives the authoritative depth and
color-device facts; pass those to `SetThemeBackground`.

Most standard controls inherit their erase behavior from that hierarchy. Static
Text is an exception: its CDEF honors an explicit `ControlFontStyleRec`
background color. When an embedded Static Text label visibly resolves to the
wrong gray, obtain the chosen `ThemeBrush` with the *owning port's actual
depth*, then set only `kControlUseBackColorMask`. Do not hard-code a 32-bit RGB
color for an 8-bit target. Do not apply this workaround to a placard label or a
root-window label whose native background already matches its parent.

For any control that still paints an opaque rectangle after a correct embedding
chain, inspect the hierarchy and the CDEF contract first. Do not cover it with
application QuickDraw merely to simulate transparency.

## Background and QuickDraw State

Use the theme/window background for the base window surface. White is appropriate for owned content surfaces such as text editors, lists, and document canvases, not as an unconditional whole-window erase.

Every custom draw routine must preserve or deliberately establish:

- current window port;
- clip region;
- origin;
- pen state, pattern, foreground, and background;
- font, face, size, and text mode.

Window and Control Manager drawing assumes an origin of `(0,0)`. Draw manager-owned controls before applying a scrolled document origin, then restore the origin. `SetOrigin` does not move the clip region; save and reconstruct clipping explicitly.

## Manager-Specific Rules

- Use the Control Manager for system control imaging. Do not manually mimic active, inactive, disabled, pressed, default, or selected chrome.
- For editable MLTE, pass `NULL` to `TXNDraw`; a non-null static draw port suppresses selection updating and can produce incorrect caret or selection behavior.
- Derive the event-loop sleep from `TXNGetSleepTicks` and run the required MLTE idle processing so the caret and text services remain live.
- Let Data Browser own its rows, selection, disclosure, header, and scrolling unless a property is explicitly custom-drawn.
- Let activation and deactivation mutate focus and active state, then let the owning manager or invalidation path redraw.

## Review Questions

Before accepting redraw code, answer:

1. Which event path owns `BeginUpdate` and `EndUpdate`?
2. Which manager or callback owns each visible rectangle?
3. Can every pixel be reconstructed from current model state after uncovering the window?
4. Are old and new bounds both invalidated after geometry or visibility changes?
5. Can an inactive or background window process the same update correctly?
6. Is any ordinary drawing occurring from commands, timers, networking, bounds changes, or idle callbacks?
7. Is each direct-drawing tracking exception bounded, clipped, and followed by a coherent final state?
8. Does any per-message, per-page, or idle path mutate a manager-owned control more often than the facts it shows settle?
