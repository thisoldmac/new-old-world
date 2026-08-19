# Appearance and File Panels

## Appearance Manager

For a normal non-Carbon application:

1. Query `gestaltAppearanceAttr`.
2. Require `gestaltAppearanceExists` before Appearance calls.
3. Interpret `gestaltAppearanceCompatMode`; do not infer Platinum solely from OS 8/9.
4. Call `RegisterAppearanceClient` before opting into Appearance behavior.
5. Balance successful registration with `UnregisterAppearanceClient`.
6. Link the executable-model-specific support: the installed RetroPPC toolchain requires `AppearanceLib`; installed classic 68K headers emit selector-trap glue.
7. Keep a standard classic path when Appearance is absent or intentionally unused.

When compatibility mode is set, systemwide Platinum mapping is disabled and unregistered applications do not automatically receive mapped System 7 definitions. When clear, standard definitions may be mapped systemwide. Test both behavior and appearance on the declared target.

Do not treat successful compilation or linkage as runtime proof. Query Gestalt and handle errors from registration/drawing calls.

## Standard File

The original Standard File Package is the broad fallback.

- Use enhanced `StandardGetFile`, `StandardPutFile`, `CustomGetFile`, and `CustomPutFile` only when `gestaltStandardFile58` is present.
- If enhanced Standard File is used, handle the Open Documents Apple event as required by the System 7 interaction model.
- Fall back to original `SFGetFile`, `SFPutFile`, `SFPGetFile`, or `SFPPutFile` where required.
- Preserve Return/default, Escape or Command-period/cancel, arrow-key, and standard folder-navigation behavior.
- Supply the appropriate color-table resource when a custom dialog requires it.

## Navigation Services

Use Navigation Services only when `NavServicesAvailable()` succeeds and the selected target permits the required runtime component.

- Native PPC links against `NavigationLib` in the installed Retro68 environment.
- Classic 68K uses the installed `Navigation` support object/library.
- The observed 68K probe required single-segment linking to avoid a relocation overflow; treat other layouts as probe-required.
- Always retain Standard File fallback unless the target contract deliberately raises the floor.

Navigation Services presence is a runtime fact, not an inference from `Navigation.h`, system version, or a successful import.
