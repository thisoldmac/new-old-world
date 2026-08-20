---
name: classic-mac-render-preview
description: Render and validate deterministic previews of classic Macintosh application UI against explicit System 6, System 7, Mac OS 8/9 Toolbox, or CarbonLib capability profiles. Use for UI mockups, screenshots, interface proposals, component feasibility checks, asset provenance audits, or requests to make a design authentic to a particular classic Mac target before implementation.
---

# Classic Mac Render Preview

Create previews that are honest about the selected machine and API surface. A plausible-looking image is not enough: validate the semantic scene first, exercise the selected target's native visual grammar and controls, record every fallback, and label the result as a preview rather than target verification.

For `platinum-carbonlib`, calibrate against the bundled Mac OS 9.1 evidence before drawing. Read [observed-carbonlib-16-os91.md](references/observed-carbonlib-16-os91.md) and inspect the relevant reference screenshots at original size. Those pixels are runtime evidence for chrome and control behavior; they are never composited into a preview or shipped as assets.

## Route the target

Choose exactly one preset before designing:

- `system6-compact`: System 6, non-Carbon Toolbox, 68K-safe, 512x342 monochrome.
- `system7-classic`: System 7, non-Carbon Toolbox, 68K or PowerPC, explicit screen and depth.
- `platinum-toolbox`: Mac OS 8 or 9, non-Carbon Toolbox with Appearance Manager.
- `platinum-carbonlib`: PowerPC CFM, Mac OS 8.6 through 9.2.2, CarbonLib 1.6.

Do not infer an API model from visual appearance. Platinum is available to both Toolbox and CarbonLib applications, but their native component sets differ.

## Default to the target's era

Treat the preset as the default presentation contract, not only as a capability ceiling.

- `platinum-carbonlib` defaults to Appearance Manager Platinum chrome, mixed-case system-font approximations, theme brushes and states, and CarbonLib-native control routes.
- Use `CreatePushButtonControl`, `CreateTabsControl`, `CreateDataBrowserControl`, `CreateBevelButtonControl`, `CreatePlacardControl`, `CreatePopupButtonControl`, `CreateSliderControl`, `CreateDisclosureTriangleControl`, `CreateImageWellControl`, Icon Services, MLTE, and related CarbonLib 1.6 primitives when they match the requested semantics. The report records the selected primitive for every component.
- For a substantial CarbonLib workspace, include target-distinguishing native facilities when the product semantics genuinely call for them: Data Browser for dense data, MLTE for rich or large text, tabs for peer panes, pop-ups for compact selection, sliders/little arrows for bounded values, image wells and Icon Services for file content, disclosure for optional detail, and placards for structural status. Do not add controls merely as decoration.
- Prefer several product-shaped scenes over a single control sampler when demonstrating breadth. Each scene should have a credible job, a distinct hero state, and a clear path to later target-runtime implementation and screenshot verification.
- Declare `application_basis` as `verified-implementation`, `evidence-backed-prototype`, or `design-concept`. Platform capability is not product evidence: CarbonLib supporting a control does not prove the named application already implements the workflow around it.
- For `verified-implementation`, use observed application states, exact receipts where practical, and the application's real minimum OS and ownership boundaries. Do not turn a separate player window into inline media, a host-owned workflow into a guest app, a planned telemetry hook into a working instrument, or a bounded model into a general expert.
- For `evidence-backed-prototype` and `design-concept`, label the status in the scene handoff and gallery. Give a concrete real-screenshot path that names the implementation seam, target OS, and state to capture.
- Do not render a CarbonLib target with System 6 monochrome window grammar, all-uppercase bitmap text, flat controls, or black-only selection by default. That is an intentional style override, not a neutral fallback.
- Match the observed Mac OS 9.1 grammar: a standard gray control-bearing window base, white recessed or document-content surfaces, ribbed Platinum title bars, connected tapered tab panes, gray beveled headers and buttons, pale blue Data Browser selection with dark text, blue progress fill, double-ring default buttons, and visibly distinct disabled states. Do not improvise System 6 geometry beneath Platinum colors.
- Treat placards as structural controls, not text containers. `CreatePlacardControl` does not draw an arbitrary title in the observed target; pair it with a sibling `CreateStaticTextControl` positioned inside the placard bounds and declare `label_mode: "adjacent-static-text"`, or omit the text.
- Render `CreateTabsControl` as a connected pane, never a floating strip. Declare the selected pane's logical children with `pane_for`, create the tab before those components, and keep every declared child inside its content bounds. The polished reference uses `CreateRootControl`; the tab CDEF and an embedding `CreateUserPaneControl` are root siblings, and pane controls attach to the User Pane with `EmbedControl`.
- Restrict QuickDraw/User Pane drawing to application-owned content such as a chart, media plane, or specialized document. Never use it to imitate buttons, tabs, lists, scrollbars, progress bars, fields, or window chrome. Treat a valid custom-content route as implementation permission, not proof that its visual result is polished.
- Allow the older visual treatment only when the scene explicitly sets `presentation.chrome` to `classic-monochrome`. Preserve the CarbonLib API target, emit the `intentional-era-override` warning, and disclose the visual/API split in the handoff.

When a request names Mac OS 8.6 through 9.2.2 and CarbonLib 1.6, choose `platinum-carbonlib` unless the user explicitly selects another executable or API model. Do not begin from the System 6 fixture and merely enlarge or recolor it.

## Promote reference evidence brutally

Generated previews are planning artifacts and can never become their own
calibration evidence. Promote a screenshot to the bundled Carbon exemplar set
only after a real target application run and an original-size visual audit.

Reject the candidate when any of these are true:

- it reads as a control sampler rather than a coherent application;
- a valid custom User Pane or QuickDraw surface still looks synthetic;
- labels, popup titles, progress, buttons, or status fields are redundant,
  clipped, unexplained, unevenly aligned, or visually detached;
- the base/background hierarchy is ambiguous, a tab strip floats, or embedded
  controls erase against the wrong Appearance background;
- Static Text or another dynamic control mutates in code but remains visually
  stale after the event loop redraws;
- placards, group boxes, separators, icons, or color exist mainly to advertise
  component breadth.

Prefer fewer excellent reference applications over broader mediocre coverage.
Keep custom-content examples outside the calibration set until their target
pixels meet the same bar as the manager-owned UI.

Read [target-contracts.md](references/target-contracts.md) for target axes and [component-contracts.md](references/component-contracts.md) before proposing or rendering UI.

## Workflow

1. For `platinum-carbonlib`, inspect the bundled evidence scene closest to the requested controls. Use it as calibration, not as a raster source.
2. Translate the request into the JSON scene format in [scene-spec.md](references/scene-spec.md). Keep content and layout semantic; do not bake system chrome into an image. Classify the application's evidence basis before choosing its hero state.
3. Run `python3 scripts/validate_preview_spec.py <scene.json>`. Stop on errors. Warnings and applied fallbacks must remain visible in the final report.
4. If the scene declares assets, run `python3 scripts/audit_assets.py <scene.json>`. Follow [asset-policy.md](references/asset-policy.md); reference images are evidence, not renderable assets.
5. Render with `python3 scripts/render_preview.py <scene.json> --output <preview.png> --report <report.json> --normalized <normalized.json>`.
6. Inspect the PNG at original size beside the relevant runtime screenshot. Confirm dimensions, palette depth, clipping, mixed-case labels, target-era window chrome, native selection color, default/focus/disabled states, and fallback treatment. Record intentional deviations.
7. Deliver the PNG, normalized scene, and report together. State the target preset, API model, calibration profile, resolved chrome model, target-native primitives, depth, warnings, fallbacks, and verification level.

## Non-negotiable gates

- Reject a Data Browser outside `platinum-carbonlib` unless the scene explicitly requests the `list` fallback.
- Treat tabs and progress indicators before Appearance Manager as custom-drawn controls. Require `allow_custom: true` or an explicit supported fallback.
- Never silently substitute a modern control, font, icon, toolbar, sidebar, translucency, antialiasing, or layout convention.
- Never use a screenshot, generated imitation, extracted system resource, or reference image as a shippable asset without provenance and rights.
- Enforce the target's pixel dimensions and indexed palette. `system6-compact` is always 512x342 at 1-bit.
- Reject accidental era drift: a preset's target-native chrome is the default, and any cross-era chrome must be explicit and reported.
- Reject evidence drift: never present a product concept, future milestone, or differently owned workflow as a verified application state merely because every visible control is available on the target.
- Reject implementation-route drift: if CarbonLib supplies the control, the preview must map to that native constructor. Custom drawing is allowed only for the product-owned content plane and must be declared `custom-required`.
- Treat the renderer's built-in glyphs and chrome as original approximations for planning. They are not extracted Apple assets and are not pixel-identical system resources.

## Output language

Use the component statuses `native`, `native-resource-route`, `native-api-route`, `custom-required`, `fallback-used`, `unsupported`, and `probe-required`.

Use the evidence statuses `verified-document`, `verified-implementation`, `verified-target`, `probe-required`, `unsupported`, and `unresolved`.

Every generated artifact is `measured-preview`. Only observation on the named OS and hardware/emulator can become `verified-target`; a good-looking PNG cannot.

The bundled Carbon screenshots are `verified-target` evidence for the reference applications on Mac OS 9.1/mac99. They calibrate the renderer, but they do not promote a newly rendered scene or a different application to `verified-target`.

Read [output-contract.md](references/output-contract.md) for the required handoff.

## Related implementation skills

After the preview is accepted, route implementation separately:

- Use `$classic-mac-toolbox-ui` for non-Carbon System 6 through Mac OS 9 UI.
- Use `$classic-mac-carbon-ui` for CarbonLib UI on Mac OS 8.6 through 9.2.2.
- Use `$classic-mac-development` when the implementation family is still ambiguous.
