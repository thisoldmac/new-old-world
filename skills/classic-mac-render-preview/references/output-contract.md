# Output contract

Deliver these together:

1. indexed-color PNG at the exact target dimensions and depth;
2. normalized JSON scene;
3. JSON validation/render report;
4. a concise human summary.

The report must include:

- `preview_status: "measured-preview"`;
- the declared `application_basis` so product evidence is not inferred from platform capability;
- target preset and resolved profile;
- calibration profile and reference evidence identifier when one is defined;
- requested and resolved chrome model, including any intentional era override;
- one status per component;
- the target-native creation or drawing primitive selected for each component;
- the window/background theme routes exercised by the preset;
- errors and warnings;
- every applied fallback;
- asset audit results;
- renderer identity and version.

The human summary must say what the preview proves and does not prove, and distinguish an observed application from a prototype or concept. Recommended wording:

> This is a capability-gated measured preview for `<preset>` using `<resolved chrome>`. It validates the declared component set, target-native implementation routes, screen geometry, palette depth, and explicit fallbacks. It is not pixel-identical system chrome and is not target-runtime verification.

If implementation follows, separately report build, test, emulator, and metal verification. Never turn `measured-preview` into `verified-target` by inference.

For `platinum-carbonlib`, mention whether the rendered scene was compared beside the bundled Mac OS 9.1 screenshots and list any intentional visual deviations. Do not call the bundled screenshot itself a preview: it is target-runtime evidence for its reference application.
