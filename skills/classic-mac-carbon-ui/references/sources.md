# Sources and Provenance

Last updated: 2026-07-22

## Primary Apple Artifacts

### CarbonLib 1.6 GM SDK

- Preserved Apple FTP artifact: <https://ftpmirror.your.org/pub/misc/apple/ftp.apple.com/developer/Development_Kits/CarbonLib_1.6GM_SDK.dmg>
- Artifact date text: June 20, 2002.
- Inspected documents:
  - `README CarbonLib SDK`
  - `Documentation/CarbonLib 1.6 TN.pdf`
  - `Documentation/CarbonPortingGuide.pdf`
  - `Documentation/CPG_Addendum_11_01.pdf`
  - `Carbon Support/Universal Interfaces/CIncludes/*`
- Authority: primary Apple content on a preservation mirror.
- Key use: compatibility envelope, feature tiers, lazy-loading/runtime detection rule, release-specific UI behavior, build requirements, and sample inventory.

### Apple Support: CarbonLib 1.6 Information and Download

- Archived Apple article: <https://web.archive.org/web/20020802065425/http://docs.info.apple.com/article.html?artnum=120047>
- Publication date: June 20, 2002; version 1.6.
- Authority: original Apple support content preserved by the Internet Archive.
- Key use: explicit released-runtime support statement for English Mac OS 8.6 through 9.2.2, plus Apple's performance and reliability description.

### Mac OS 8 Human Interface Guidelines

- Apple document mirror: <https://dev.os9.ca/techpubs/mac/pdf/HIGOS8Guidelines.pdf>
- Publication: Apple Computer, Inc., 1997.
- Authority: primary Apple document on a preservation mirror.
- Key use: Platinum appearance, controls, dialogs, layout, menus, windows, fonts, and control-panel navigation.

### Macintosh Human Interface Guidelines

- Apple Computer, Inc., 1992/1995 edition discovery copy: <https://apps.hci.rwth-aachen.de/borchers-old/cs377a/handouts/HIGuidelines.pdf>
- Status: retained as the general pre-Platinum foundation; the skill's exact numeric rules come from the Mac OS 8 supplement.
- Key use: general Macintosh interaction principles not replaced by the Mac OS 8 supplement.

### Current Apple archive and documentation

- Apple Documentation Archive filtered for Carbon: <https://developer.apple.com/library/archive/navigation/index.html?filter=carbon>
- Apple-authored `Handling Carbon Windows and Controls`, preserved mirror: <https://leopard-adc.pepas.com/documentation/Carbon/Conceptual/HandlingWindowsControls/hitb-wind_cont_tasks/hitb-wind_cont_tasks.html>
- Apple-authored `Carbon Event Manager Programming Guide`, preserved PDF: <https://leopard-adc.pepas.com/documentation/Carbon/Conceptual/Carbon_Event_Manager/CarbonEvents.pdf>
- `Inside Macintosh: Macintosh Toolbox Essentials`: <https://developer.apple.com/legacy/library/documentation/mac/pdf/MacintoshToolboxEssentials.pdf>
- Apple-authored `Inside Macintosh: Text`, preserved mirror: <https://vintageapple.org/inside_r/pdf/Text_1993.pdf>
- `gestaltAppearanceCompatMode`: <https://developer.apple.com/documentation/coreservices/1472012-appearance_manager_attribute_sel/gestaltappearancecompatmode?preferredLanguage=occ>
- Key use: Carbon standard-handler redraw ownership, native control and tab-pane behavior, classic update regions, TextEdit updates, and the Appearance Manager compatibility-mode concept.
- Caution: current macOS HIG and Cocoa guidance are not authority for classic Mac OS 8/9 UI.

## Local Primary Interface Evidence

- Retro68 Universal Interfaces: `/Users/michelle/Lab/Tools/Retro68-build/toolchain/universal/CIncludes`
- Retro68 Rez interfaces: `/Users/michelle/Lab/Tools/Retro68-build/toolchain/universal/RIncludes`
- Retro68 PowerPC libraries: `/Users/michelle/Lab/Tools/Retro68-build/toolchain/universal/libppc`
- Key headers inspected: `Appearance.h`, `CarbonEvents.h`, `MacWindows.h`, `Controls.h`, `ControlDefinitions.h`, `Gestalt.h`, `Icons.h`, `MacHelp.h`, `AppleHelp.h`, `Menus.h`, `Navigation.h`, and `MacTextEditor.h`.
- Authority: Apple interface declarations as packaged in the local toolchain. Availability comments describe the header snapshot, not a complete runtime guarantee.

## Project Implementation Evidence

- NOW guest source: `/Users/michelle/Lab/Code/timbottu/now/guest/src`
- NOW architecture notes: `/Users/michelle/Lab/Code/timbottu/now/docs/architecture.md` and `/Users/michelle/Lab/Code/timbottu/now/docs/nested-loops.md`
- Key use: evidence for Retro68 build shapes, UPP ownership, standard windows, Appearance Manager, Data Browser, Navigation Services, and cooperative nested-loop pumping.
- Authority limit: one application's implementation cannot establish general platform availability.

## Apple Sample-Code Evidence

- CarbonLib 1.6 SDK samples inspected: `BasicDataBrowser`, `NavSample`, and their `SIZE` resources.
- Key use: Data Browser setup and callback sequence; Navigation event UPPs, `NavLibraryVersion`, custom-event routing, and teardown; process flags and memory partition examples.
- Authority limit: sample architecture demonstrates intended usage, not universal product requirements or target validation.

## Secondary Discovery Sources

Secondary sources may locate artifacts or supply contemporary context, but do not promote an API/version claim from them without primary or target-run confirmation.

- MacTech preservation archive.
- Macintosh Repository.
- GUIdebook and other visual archives for screenshot corroboration only.

## Citation Practice Inside This Skill

When adding a platform claim, record:

1. source title and URL or exact local path;
2. document/header version and date where available;
3. function, selector, or section name;
4. applicable OS and CarbonLib range;
5. whether the claim was reproduced on target.
