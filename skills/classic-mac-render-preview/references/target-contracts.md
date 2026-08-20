# Target contracts

The preset is a compatibility contract, not merely a theme.

| Preset | OS range | CPU | API model | Default screen | Allowed depths | Default chrome |
|---|---|---|---|---|---|---|
| `system6-compact` | System 6.0.4-6.0.8 | 68K | non-Carbon Toolbox | 512x342 | 1 | classic monochrome |
| `system7-classic` | System 7.0-7.6.1 | 68K or PPC | non-Carbon Toolbox | 640x480 | 1, 4, 8 | classic color or monochrome at selected depth |
| `platinum-toolbox` | Mac OS 8.0-9.2.2 | 68K or PPC | non-Carbon Toolbox plus Appearance Manager | 800x600 | 1, 4, 8 | Appearance Manager Platinum |
| `platinum-carbonlib` | Mac OS 8.6-9.2.2 | PPC CFM | CarbonLib 1.6 | 800x600 | 1, 4, 8 | Appearance Manager Platinum with Carbon-native control routes, calibrated to observed Mac OS 9.1 |

## Independent axes

Record all of these even when a preset supplies defaults:

- minimum and maximum OS;
- CPU family;
- Toolbox or CarbonLib API model;
- screen width and height;
- pixel depth and palette;
- classic or Platinum appearance;
- font/resource policy;
- optional manager assumptions.

Changing one axis does not silently change another. In particular, a Platinum-looking non-Carbon app does not gain Carbon Data Browser capability.

## Chrome resolution

Omitting `presentation.chrome` means `target-native`; it resolves to the preset's default chrome above. This is the normal path.

`presentation.chrome: "classic-monochrome"` is an explicit cross-era visual override. It is valid for deliberate visual continuity, but it never changes the executable/API target, never upgrades a custom drawing route to native, and always emits `intentional-era-override` outside `system6-compact`.

For `platinum-carbonlib`, target-native rendering must expose the Appearance Manager contract in both the image and report: a standard gray control-bearing base, white recessed or document-content surfaces, Platinum window frame treatment, connected native tab panes, mixed-case text, theme-aware bevels and states, color selection at color depths, and exact CarbonLib creation or drawing primitives for components.

## Observed CarbonLib calibration

`platinum-carbonlib` uses the `macos91-carbonlib16-native-exemplar-v4` calibration profile. It comes from five screenshots of four native-only PowerPC CFM reference applications running at 800x600 on Mac OS 9.1 under mac99. The applications gate CarbonLib 1.6 and Appearance Manager at startup, establish a root-control and embedding-pane hierarchy, exercise Icon Services and manager-owned content, contain no application QuickDraw drawing, and had their PEF imports audited before capture.

Read [observed-carbonlib-16-os91.md](observed-carbonlib-16-os91.md) for the screenshot manifest, observed chrome, and control-specific notes. This calibration is the default visual basis for CarbonLib previews. It does not claim that Mac OS 8.6, 9.0.4, 9.2.2, alternate Appearance themes, or different font installations are pixel-identical; mark those as runtime variants when exact pixels matter.

## Screen rules

- `system6-compact` is fixed at 512x342 and 1-bit.
- Other presets accept explicit screen dimensions no smaller than 512x342.
- Depth must be one of the preset's allowed indexed depths. This renderer intentionally does not emit 16-bit or 32-bit previews because those would weaken palette gating.
- Layout coordinates are global screen pixels. The menu bar occupies the top 20 pixels.

## Interpretation boundary

The renderer models feasibility and broad native visual grammar. Its original bitmap glyphs and drawn chrome do not claim pixel identity with Chicago, Charcoal, Appearance Manager, or a specific ROM/system file.
