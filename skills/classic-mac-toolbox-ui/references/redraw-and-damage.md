# Classic Toolbox Redraw and Damage Contract

Use this contract for normal non-Carbon applications. Do not import Carbon Event or HIView ownership rules.

## Update Event Ownership

The Window Manager accumulates damaged areas in a window's update region. `WaitNextEvent`, `GetNextEvent`, or `EventAvail` reports an `updateEvt` when that region is nonempty. Update events may arrive while the application is foreground or background.

For every `updateEvt`:

```c
GrafPtr savedPort;
WindowPtr window = (WindowPtr)event.message;

GetPort(&savedPort);
SetPort(window);
BeginUpdate(window);
DrawWindowContents(window);
EndUpdate(window);
SetPort(savedPort);
```

Always match `BeginUpdate` with `EndUpdate`. `BeginUpdate` clips the visible region to the old update region and clears the update region. Failing to call it causes repeated update events.

## Manager Ownership and Draw Order

Inside `DrawWindowContents`:

1. establish the window background only where the application owns it;
2. call `UpdateControls(window, window->visRgn)` for controls needing update;
3. update other manager-owned surfaces such as `LUpdate` and `TEUpdate`;
4. draw application-owned content;
5. draw a grow box only when the selected window definition does not already own it.

The Dialog Manager updates ordinary dialog items when the application routes the update to it. A dialog user item remains application-owned and must draw every required state from its user-item procedure.

Use white only for content surfaces that call for it, such as an editable text area or list. Preserve the standard gray or Appearance background for the base window/dialog surface.

## Mutation and Damage

For ordinary state changes:

1. mutate model state;
2. recompute geometry;
3. invalidate affected rectangles or regions;
4. return to the event loop;
5. draw from the next update event.

Invalidate both old and new bounds when content moves, resizes, hides, or changes panes. Do not draw from null events, timers, networking callbacks, menu commands, or resize calculations merely because the display should eventually change.

Full-window invalidation is a conservative fallback, not the default for a local change.

## Direct-Drawing Exceptions

Immediate drawing is valid during tracking or continuous scrolling when delayed feedback would be incorrect. Use an action callback where available, clip to the owned content, and use `ScrollRect` or equivalent region movement to preserve unchanged pixels and invalidate newly exposed areas.

The final model state must reproduce the same display during a later update. Direct tracking feedback must not become the only copy of state.

## Origins, Clipping, and QuickDraw State

Window and Control Manager routines expect the port origin at `(0,0)`. Perform manager drawing first, then set a document origin if needed, draw document content, and restore the origin.

`SetOrigin` does not move the clip region. Save and restore the clip explicitly. Preserve the port, origin, clip, pen, colors, patterns, font, face, size, and text mode around custom drawing.

## Review Questions

1. Does every update event enter one balanced `BeginUpdate`/`EndUpdate` cycle?
2. Does each visible rectangle have exactly one drawing owner?
3. Can uncovering or background updating reconstruct the whole display?
4. Are old and new bounds invalidated after movement or visibility changes?
5. Are TextEdit, List Manager, Control Manager, Dialog Manager, and user-item responsibilities distinct?
6. Is any direct drawing outside an update handler a documented tracking or immediate-feedback exception?
