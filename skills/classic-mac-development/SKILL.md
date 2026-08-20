---
name: classic-mac-development
description: Route classic Macintosh software work to the correct specialized skill across normal non-Carbon Toolbox applications, CarbonLib applications, and 68K INITs or resident system extensions. Use for broad or ambiguous classic Mac development requests involving System 6, System 7, Mac OS 8 or 9, 68K, PowerPC, CFM, CarbonLib, UI/UX, redraws and update events, builds, resources, packaging, extensions, or compatibility when the correct application model and skill are not already explicit.
---

# Classic Mac Development

Classify the software artifact and API model before giving implementation advice. Invoke the smallest set of specialized skills that fully covers the request.

## Route by Artifact and Runtime

| Request | Primary skill |
|---|---|
| Normal non-Carbon application UI, System 6/7 classic UI, or non-Carbon Platinum UI | `classic-mac-toolbox-ui` |
| Normal non-Carbon application build, event loop, memory, ABI, resources, CFM, or packaging | `classic-mac-toolbox-platform` |
| CarbonLib PowerPC application UI on Mac OS 8.6–9.2.2 | `classic-mac-carbon-ui` |
| CarbonLib PowerPC application platform/build/runtime work | `classic-mac-carbon-platform` |
| 68K INIT, startup execution, trap patch, or resident system extension | `classic-mac-init-platform` |
| Launching, driving, observing, or tearing down an emulator (headless QEMU mac99/q800) to verify any of the above | `classic-mac-emulator-harness` |

Invoke both the UI and platform peer for implementation work crossing those layers. Do not invoke all skills indiscriminately.

`classic-mac-emulator-harness` is cross-cutting: invoke it alongside the selected platform or UI skill whenever a task actually runs the artifact on an emulator, so acceptance testing goes through the blessed control plane instead of rediscovering it — and re-falling into the cursor loop — each time.

Route redraw, invalidation, update-region, clipping, stale-pixel, flicker, tab-pane, manager-drawing, and custom-control paint problems to the applicable UI skill first. Also invoke its platform peer when the cause may be event dispatch, background updates, nested tracking loops, timers, or service callbacks.

For a stated CarbonLib 1.6 target, reject a System 6-style visual shortcut even when it is technically valid classic Mac UI. The Carbon UI skill must exercise the requested Carbon managers and Appearance chrome; the render-preview skill may make a measured preview, but only real target screenshots can calibrate or replace native-reference evidence.

## Resolve the Boundary

Ask or inspect only what materially changes routing:

1. Is the artifact a normal application, INIT/system extension, driver, control panel, desk accessory, plug-in, or something else?
2. Is the application classic non-Carbon Toolbox or CarbonLib?
3. Is the executable classic 68K `CODE`, native PPC CFM, CFM-68K, or fat?
4. What is the exact lowest system and hardware row?
5. Is the task interaction design, implementation, build/package, runtime diagnosis, or acceptance testing?

If the repository answers these questions, inspect it instead of asking the user.

## Enforce Family Boundaries

- Do not use Carbon APIs merely because the target is Mac OS 8 or 9.
- Do not apply normal-application event loops, heaps, or A5 assumptions to INITs.
- Do not treat CFM-68K as the default 68K path.
- Do not infer target support from a header, successful compile, link, package, or emulator launch on another row.
- Treat drivers, desk accessories, control panels, XCMD/XFCN modules, ROM patches, and Mac OS X as separate scopes requiring dedicated research or an explicit narrow analysis.

## Return the Routing Decision

For a broad request, state briefly:

- selected artifact/runtime profile;
- selected specialized skill or skill pair;
- excluded neighboring profiles;
- missing target fact that remains probe-required.

Then continue with the selected skill instead of expanding this router into domain guidance.
