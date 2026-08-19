# Runtime Capability Gates

Compilation against Universal Interfaces and linkage against CarbonLib prove only that glue exists. CarbonLib 1.6 lazily loads several backing libraries, and Apple explicitly warns that imported t-vectors may be non-null when the service is absent.

## Gate Order

1. `Gestalt(gestaltSystemVersion, ...)` for Mac OS 8.6 or later.
2. `Gestalt(gestaltCFMAttr, ...)` and the `gestaltCFMPresent` bit for a PowerPC CFM application.
3. `Gestalt(gestaltCarbonVersion, ...)` for the declared CarbonLib floor.
4. Probe each optional facility below.
5. Exercise its smallest harmless operation and handle its returned error.

Treat `Gestalt` failure as absence. Log selector values in hexadecimal so target reports are reproducible.

## Facility Map

| Facility | Primary runtime probe | Additional rule or fallback |
|---|---|---|
| Appearance Manager | `gestaltAppearanceAttr`, bit `gestaltAppearanceExists`; read `gestaltAppearanceVersion` when available | If Appearance is absent or compatibility mode is active, do not assume Platinum rendering. A CarbonLib 1.6 application may refuse launch rather than maintain a second hand-drawn theme. |
| CarbonLib | `gestaltCarbonVersion` | Require 1.6 for the blessed path. Do not infer from linked symbols. |
| Carbon Events | CarbonLib version plus tested installation of the first required handler | `RunApplicationEventLoop` is declared for 1.1+. Keep a `WaitNextEvent` seam only for an existing architecture or controlled fallback. |
| Navigation Services | `NavServicesAvailable()`; then `NavLibraryVersion()` | On CFM, the macro checks that `NavLibraryVersion` resolved and `NavServicesCanRun()` succeeds. Fall back to a deliberately supported Standard File path or disable the command. |
| MLTE or Textension | Resolve Textension when supporting systems outside the fixed 1.6 image; call `TXNVersionInformation()` before feature-specific use | The call returns a version and MLTE feature bits. Fall back to TextEdit only for small, simple text. |
| ATSUI | `gestaltATSUVersion`; use `gestaltATSUFeatures` for feature-level work | Use QuickDraw and system-font text if Unicode shaping is not required. Do not infer all ATSUI 2.x behavior from presence. |
| Icon Services | `gestaltIconUtilitiesAttr`, bit `gestaltIconUtilitiesHasIconServices` | `GetIconRef*` annotations name IconServicesLib 8.5+ and CarbonLib 1.0+. Fall back to application icon-family resources. Release every acquired `IconRef`. |
| Drag Manager | `gestaltDragMgrAttr`, bit `gestaltDragMgrPresent` | Gate drag images separately with `gestaltDragMgrHasImageSupport`. Provide menu or button equivalents for drag-only actions. |
| Contextual menus | `gestaltContextualMenuAttr`, bit `gestaltContextualMenuTrapAvailable` | Contextual menus supplement, never replace, a visible menu or control path. |
| Window Manager extensions | `gestaltWindowMgrAttr` and feature bits | Gate floating windows, buffering, and live resize separately. Do not test one bit and infer the rest. |
| Menu Manager extensions | `gestaltMenuMgrAttr` and masks | The headers distinguish bit indexes from masks; use the named mask constants. Ignore Aqua-only bits on the classic target. |
| Help tags and Help menu | Exact `HM*` call plus returned status | `gestaltHelpMgrAttr` describes the older Help Manager family; it is not a blanket guarantee for Apple Help Viewer. |
| Apple Help Viewer | Resolve and call the exact `AH*` API and handle failure | Header annotations do not prove the Help Viewer application and content are usable on every installation. Keep concise in-app or static help when integration fails. |
| Data Browser | CarbonLib 1.6 product gate, successful `CreateDataBrowserControl`, and callback smoke test | There is no useful dedicated Gestalt selector in the reviewed interfaces. Treat creation and callback errors as the boundary. Avoid an untested legacy fallback if list behavior is core. |
| Keychain | Mac OS 9+ plus exact Keychain API resolution and returned status | Apple lists Keychain as a Mac OS 9 facility. Never silently store credentials less securely on 8.6. |

When no Gestalt selector exists, Apple's 1.6 note recommends `GetSharedLibrary`. Use the exact import-library name from the relevant SDK and build. Do not cargo-cult a library name from another SDK release.

## UI Response to Absence

- Required shell capability absent: present one plain startup alert naming the required OS or CarbonLib version and quit cleanly.
- Optional feature absent: disable or omit the command and explain why in nearby static text or help.
- Data or security facility absent: preserve data and security semantics; never substitute a lossy or insecure path without explicit product approval.
- Runtime error after a successful probe: treat it as a normal failure path, not an assertion.
