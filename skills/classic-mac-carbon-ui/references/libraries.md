# Library and UI Technology Map

The CarbonLib 1.6 SDK and local Retro68 Universal Interfaces expose many import libraries. Their presence in the toolchain is compile-time evidence only. The target system must still provide the backing manager or shared library.

## Blessed UI Stack

| Layer | Interfaces or library family | Appropriate use |
|---|---|---|
| Application and CFM shell | CarbonLib, InterfaceLib, CFrag Manager | PowerPC application launch, classic Toolbox baseline, Carbon glue |
| Native look | AppearanceLib and Appearance Manager | theme backgrounds, brushes, fonts, state drawing, metrics |
| Windows, menus, dialogs, controls | WindowsLib, MenusLib, DialogsLib, ControlsLib | standard structure and interaction |
| Event dispatch | Carbon Event Manager through CarbonLib | command routing, standard handlers, application and window event loops |
| Drawing | QuickDraw and Appearance drawing APIs | content, clipping, regions, pixmaps, native custom-control composition |
| Lists and outlines | Data Browser through CarbonLib and Control Manager | compact lists, columns, hierarchy, sorting, selection, disclosure |
| Files | NavigationLib and Navigation Services | Open, Save, Choose Folder, file filtering, custom panes |
| Text | TextEdit baseline; Textension or MLTE; ATSUnicodeLib or ATSUI | simple small text; rich or large text; Unicode layout when justified |
| Icons | classic icon resources and IconServicesLib | app and module identity; semantic system, file, and folder icons |
| Direct manipulation | DragLib and ContextualMenu | drag and drop and secondary contextual actions with visible alternatives |
| Help | Mac Help tags/menu and Apple Help Viewer APIs | contextual control help and full help books, each independently gated |
| Preferences and credentials | Resource or Preferences APIs; KeychainLib on Mac OS 9+ | durable settings; credentials only with a secure gated path |
| Networked UI | Open Transport libraries | nonblocking transport integrated with the cooperative event pump |

## Available but Not a Default UI Foundation

- QuickTime, Color Picker, ColorSync, Speech, HTML Rendering, AppleGuide, and URL Access may support a specific feature, but none should define the main application shell without a separate capability and memory case.
- QuickDraw GX, QuickDraw 3D, DrawSprocket, InputSprocket, and game or media libraries are not substitutes for standard application UI.
- Core Graphics, Quartz, Aqua layout, sheets, compositing, and other Mac OS X facilities may appear in the same later header snapshot. A `Mac OS X: available` annotation with `CarbonLib: not available` is a hard stop for the classic target.
- CFString can appear in Carbon creation APIs, but Core Foundation surface area varies. Use only the exact CarbonLib-annotated functions required by the chosen control and verify lifetime rules.

## Selection Rule

Choose a facility because it owns the needed classic behavior, not because its import library exists. For each nonbaseline facility record: header annotation, CarbonLib floor, backing service, runtime probe, memory and liveness cost, fallback, and target-run evidence.
