# Platform and Capability Matrix

This matrix is intentionally conservative. It distinguishes facts from the Apple SDK documents from validation work that remains to be performed.

## Recommended Product Contract

| Axis | Blessed path | Why |
|---|---|---|
| CPU | PowerPC CFM application | CarbonLib on classic Mac OS is a PowerPC path; it also matches the current Retro68/NOW envelope. |
| Minimum OS | Mac OS 8.6 | Apple identifies 8.6 as the compatibility floor for CarbonLib 1.2 and its high-level event/UI additions. |
| Deployed CarbonLib | 1.6, with version checked at launch | The selected runtime provides the mature classic implementation and documented fixes; header or link success alone is insufficient. |
| Maximum validation OS | Mac OS 9.2.2 | Apple's CarbonLib 1.6 support article explicitly names Mac OS 8.6 through 9.2.2; direct validation is still required. |
| Primary UI | Appearance-aware Toolbox controls and standard Window Manager behavior | Preserves Platinum semantics, theme colors, native states, and system-font behavior. |
| Event model | Carbon Events plus standard handlers | Apple's preferred high-level model for the 8.6/CarbonLib 1.2+ envelope. |
| Drawing | QuickDraw plus Appearance Manager primitives | Native to classic Mac OS; avoid Quartz/Aqua-only assumptions. |
| Files | Navigation Services | Apple identifies it as the Carbon replacement for Standard File dialogs. |
| Rich text | MLTE when the feature justifies its memory and complexity | Supports Unicode, more than 32 KB, scrolling, input methods, undo, and printing; availability still needs runtime gating. |

## OS Release Validation Matrix

| System | What is presently established | Required validation before claiming support |
|---|---|---|
| Mac OS 8.6 | CarbonLib 1.2 compatibility floor; Carbon Events and Data Browser are in Apple's 1.2 capability set; MLTE is documented for 8.6 and later. | Install/version behavior for CarbonLib 1.6; every backing library probe; 8-bit and 16-bit color; 640 by 480; low-memory launch; alternate system font; all window/control states. |
| Mac OS 9.0 / 9.0.4 | CarbonLib shipped with Mac OS 9 in earlier forms; Keychain Manager is listed as a Mac OS 9 addition. | Exact bundled CarbonLib revisions; interaction with installed 1.6; Keychain selector; Navigation, Data Browser, Help, MLTE, ATSUI, and Appearance versions. |
| Mac OS 9.1 | Inside the broad classic target but not separately characterized by the sources reviewed so far. | Same functional suite plus installation, launch, menu, dialog, sleep/wake, networking, and memory checks. |
| Mac OS 9.2.1 | Explicitly named by the CarbonLib 1.6 SDK README. | Full regression suite using the 1.6 runtime. |
| Mac OS 9.2.2 | Apple's June 20, 2002 CarbonLib 1.6 support article explicitly includes English Mac OS 8.6 through 9.2.2. | Full regression suite using the installed 1.6 runtime. |

Do not turn an empty or provisional cell into an absence claim. It means the current research has not yet established the fact.

## Runtime Gate Sequence

1. Call Gestalt with `gestaltSystemVersion` and reject systems below the product floor.
2. Call Gestalt with `gestaltCarbonVersion` and reject or degrade below the required CarbonLib version.
3. Probe each independently shipped or lazily loaded service with its Gestalt selector.
4. If Apple documents no selector, resolve the backing library with `GetSharedLibrary` before calling its glue.
5. Prefer a lower-level native fallback where one is genuinely supportable; otherwise disable the feature with a concise explanation.
6. Log the observed OS, CarbonLib, service versions, screen depth, dimensions, and memory at diagnostic launch.

## Capability Tiers

### Baseline shell

- standard document, utility, movable-modal, and alert roles;
- menus and command-key equivalents;
- Appearance Manager backgrounds, fonts, and drawing primitives;
- native buttons, checkboxes, radio buttons, scroll bars, pop-ups, and edit/static text;
- QuickDraw content and resource-backed icons/strings.

### CarbonLib 1.1+ controls

- Data Browser;
- tab control creation API;
- disclosure triangle creation API;
- progress bar creation API;
- icon control creation API;
- pop-up button creation API.

### CarbonLib 1.1+ event architecture

- `RunApplicationEventLoop` and `QuitApplicationEventLoop` are declared for CarbonLib 1.1+;
- standard application/window handlers and command routing are the preferred new-code structure;
- retain a deliberate seam when integrating with a mature `WaitNextEvent` application.

### CarbonLib 1.2-era facility set

- Carbon Event Manager and standard event handlers;
- Data Browser as an Apple-documented addition at this tier;
- ATSUI, XML, URL Access, Interface Builder Services, Font Sync, Apple Help Viewer, and Font Management;
- MLTE documented as available at this tier and on Mac OS 8.6+.

The 1.1-versus-1.2 Data Browser wording is a documentation-layer discrepancy: the Universal Interfaces creation API says CarbonLib 1.1+, while the Porting Guide groups Data Browser with the 1.2 additions. It does not alter a CarbonLib 1.6 product floor; preserve both facts when describing older floors.
