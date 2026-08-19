# Research Ledger

Last updated: 2026-08-02

This ledger separates confirmed platform facts from useful but unverified recollection. Promote a claim into the skill only when its source and scope are explicit.

## Contents

- Evidence labels
- Authority order
- Verified findings
- Local implementation evidence
- Residual evidence boundaries

## Evidence Labels

- **Verified:** supported by an Apple primary document, an Apple Universal Interfaces availability block, or a reproduced target run.
- **Provisional:** supported by a credible secondary source, code that has not been run across the declared matrix, or an inference from adjacent evidence.
- **Unresolved:** conflicting evidence or missing version-specific confirmation.

## Authority Order

1. observed behavior on the declared OS, CarbonLib, hardware, and color-depth target;
2. Apple CarbonLib release notes and Apple developer documentation from the relevant period;
3. Universal Interfaces availability annotations plus runtime feature detection;
4. original Apple HIG material for behavior and layout;
5. current project code as implementation evidence only;
6. preservation sites and contemporary third-party articles as discovery or corroboration.

## Verified Findings

### CarbonLib is not a monolithic capability guarantee

The CarbonLib 1.6 Tech Note says CarbonLib imports functions from other system libraries, so a function present in CarbonLib can still be unavailable on an older system. Version 1.6 also replaced some weak imports with lazy-loading glue. Consequently, a non-null t-vector is not sufficient proof. Apple recommends Gestalt, or `GetSharedLibrary` when a library has no Gestalt selector.

Implication: gate the OS version, CarbonLib version, and backing service independently. Never use header presence or successful linkage as the only test.

### CarbonLib 1.6 officially covers Mac OS 8.6 through 9.2.2

The CarbonLib 1.6 SDK README describes development through Mac OS 9.2.1, while Apple's June 20, 2002 support article for the released CarbonLib 1.6 download explicitly identifies English Mac OS 8.6 through 9.2.2. This resolves the documentation-scope question. It does not replace direct application testing on either endpoint.

### CarbonLib 1.2 established the 8.6-era high-level UI path

Apple's June 2001 Carbon Porting Guide lists CarbonLib 1.2 as compatible back to Mac OS 8.6 and identifies Data Browser, Carbon Event Manager, ATSUI, XML, URL Access Manager, Interface Builder Services, Font Sync, Apple Help Viewer, and Font Management among its additions. It separately lists Keychain Manager as requiring Mac OS 9.

Implication: a PowerPC application whose product floor is 8.6 and whose deployed runtime is CarbonLib 1.6 can use the Carbon Event Manager and Data Browser as part of its preferred architecture, subject to API-level availability and real-target tests.

### Carbon Events are the preferred high-level event model in this envelope

The Carbon Porting Guide calls Carbon Event Manager the most important optional Carbon technology, describes `RunApplicationEventLoop` as replacing the direct `WaitNextEvent` loop, and recommends installing standard handlers before custom handlers. It also notes that `CreateNewWindow` can install the standard window handler and standard window controls.

Implication: prefer Carbon Events and standard handlers for new UI structure. Preserve a deliberate compatibility seam if integrating into an existing `WaitNextEvent` application rather than forcing a risky wholesale conversion.

### Carbon draw-content and manual update ownership are mutually exclusive

Apple's `Handling Carbon Windows and Controls` says the standard handler has already called `SetPort` and `BeginUpdate` before sending `kEventWindowDrawContent`, draws intersecting system controls before the application handler, and calls `EndUpdate` afterward. An application that needs to own those operations should handle `kEventWindowUpdate` instead.

Implication: a standard draw-content handler draws only application-owned content. It must not call `BeginUpdate`, `EndUpdate`, `DrawControls`, or `UpdateControls`. A window that deliberately overrides update ownership must own the complete cycle and must not also execute the standard draw-content path.

### Ordinary changes invalidate; tracking may draw immediately

`Inside Macintosh: Macintosh Toolbox Essentials` defines the classic update region as accumulated damage and documents invalidation followed by update-event drawing. Apple's Carbon window/control guide separately demonstrates immediate content drawing from control-action callbacks for live scrolling and recommends region-moving routines when optimizing the newly exposed area.

Implication: commands, timers, services, and layout changes mutate model state and invalidate old and new bounds. Direct drawing outside the normal owner is permitted only for bounded tracking or immediate feedback, and the next ordinary update must reproduce the same display from model state.

### Native managers retain redraw ownership

The Carbon guide assigns visual feedback and drawing of system-defined controls to the standard handler, uses embedded User Pane controls for tab panes, and switches panes with `SetControlVisibility(..., true)` after clearing focus. The installed headers expose `EmbedControl`, `AutoEmbedControl`, User Pane draw callbacks, and Data Browser mutation and custom-item drawing APIs in the CarbonLib 1.x envelope.

Implication: tabs are a native tab control plus real embedded panes, not detached painted chrome. Standard controls and ordinary Data Browser content are not redrawn by the window's custom QuickDraw code.

### MLTE has two distinct update contracts

The installed `MacTextEditor.h` says `TXNUpdate` internally calls `BeginUpdate` and `EndUpdate` and is inappropriate when a window contains anything besides that TXNObject. It says composite windows should call `TXNDraw` from their enclosing update event and that editable objects should use a `NULL` draw port so selection and caret behavior remain correct.

Implication: use `TXNUpdate` only for an MLTE-only window. Composite windows own the update cycle and call `TXNDraw(object, NULL)`; use `TXNForceUpdate` to request MLTE damage.

### Platinum fidelity comes from system primitives, not pixel imitation

Apple's Mac OS 8 Human Interface Guidelines says applications should use Toolbox-generated controls, windows, and alerts whenever possible, use Appearance Manager colors for custom elements, and follow the supplied layout rules. It warns that appearance can change while layout does not, and that the user may change accent colors and the system font.

Implication: use Appearance Manager and native controls. Mockups must demonstrate classic structure, but implementation must not freeze the screenshot's exact grays, font, or theme state into custom drawing.

### Font layout must tolerate user choice

The Mac OS 8 HIG identifies Charcoal as the default system font but recommends laying out dialog boxes and control panels against Chicago metrics because Charcoal is metrically based on it and the user may select another system font.

Implication: obtain theme/system fonts and leave metric-safe room. Do not hardcode a modern web font or assume only Charcoal.

### Verified API availability samples

The local Universal Interfaces headers declare:

- `SetThemeWindowBackground`: CarbonLib 1.0 and later;
- `DrawThemeTabPane`, `DrawThemeTab`, and `DrawThemeButton`: CarbonLib 1.0 and later;
- `CreateDisclosureTriangleControl`, `CreateProgressBarControl`, `CreateTabsControl`, `CreateIconControl`, `CreatePopupButtonControl`, and `CreateDataBrowserControl`: CarbonLib 1.1 and later;
- `NavGetFile`, `NavPutFile`, and `NavChooseFolder`: CarbonLib 1.0 and later;
- `TXNNewObject`, `TXNDraw`, and `TXNSetData`: CarbonLib 1.0 and later in the later Universal Interfaces snapshot;
- `GetIconRefFromFile` and `GetIconRef`: CarbonLib 1.0 and later, with non-Carbon IconServicesLib 8.5 availability also annotated.

These declarations prove the CarbonLib floor stated by that header snapshot. They do not erase the CarbonLib 1.6 Tech Note's requirement to test backing services at runtime.

### CarbonLib 1.6 contains UI behavior that affects application design

The 1.6 Tech Note records, among other changes:

- standard window handlers idle controls after activation;
- new window collapse/expand events;
- improved mouse-moved behavior for controls;
- Data Browser memory use returned toward pre-1.5 levels at a possible scrolling-cost tradeoff;
- Appearance Manager support for additional brushes;
- multiple fixes for menus, help tags, timers, transitions, and control behavior.

Implication: the deployed 1.6 runtime is not merely a linker shim; it materially changes event, control, and memory behavior. Verification must use the actual runtime version.

### Exact Platinum layout metrics are transcribed

The Mac OS 8 HIG diagrams establish standard control heights, label baselines, focus and default-ring exclusions, dialog margins, and inter-control spacing. These are recorded in `layout-metrics.md`, including the 20-pixel push button, 58-by-20 OK and Cancel buttons, 22-pixel edit field, 12-pixel progress bar, and group-box insets.

Implication: visual design and review can now be measured against period Apple guidance rather than a screenshot approximation.

### Runtime probes are facility-specific

The Universal Interfaces reviewed provide direct probes for Appearance, CarbonLib, ATSUI, Window Manager, Menu Manager, Icon Services, Drag Manager, and contextual menus. Navigation Services supplies `NavServicesAvailable()` and `NavLibraryVersion()`; MLTE supplies `TXNVersionInformation()`. Data Browser has no useful dedicated Gestalt selector in this interface set, so the CarbonLib gate, control creation result, and callback smoke test form its practical boundary.

### Control mutation is a repaint the caller schedules

Observed on a CarbonLib 1.6 target run (2026-08-02): a Data Browser list fed one `AddDataBrowserItems` call per 16-row page of a network-delivered listing repainted the whole visible control once per page, while every application-issued invalidation remained bounded. The same immediate-redraw behavior is documented for classic control mutation calls (`SetControlTitle`, `HiliteControl`) in Inside Macintosh's Control Manager material.

Measured on an emulated target (mac99, Mac OS 9.1, CarbonLib 1.6, 2026-08-02) with per-property item-data counters and `GetWindowRegion(kWindowUpdateRgn)` sampling, driving one mutation per event-loop pass: `AddDataBrowserItems` and `RemoveDataBrowserItems` performed no synchronous drawing (zero item-data requests inside the call) and left the update region covering the control's entire list content area regardless of which rows changed — including rows entirely below the scrolled-visible range. Damage coalesced per event-loop pass: eight 16-row adds issued within one pass produced one repaint of the visible rows (12 row draws), while the same eight adds issued one per pass produced eight (96 row draws). **Verified** for that emulated configuration; real-hardware confirmation of the region scope remains **provisional** (the amplification behavior itself was observed on hardware first).

Implication: the mutation cadence is application-owned damage even though the drawing is not. `redraw-and-damage.md` carries the resulting rule: mutate once per settled answer, diff per keystroke, compare before re-asserting on idle paths.

## Local Implementation Evidence

The NOW guest currently demonstrates a practical subset of this stack: document and movable-modal windows, Appearance Manager backgrounds and fonts, Data Browser, Navigation Services, `WaitNextEvent`, modal filters, and `TrackControl` action procedures. Its architecture documentation also records the cooperative-liveness rule that nested Toolbox loops need pump callbacks when the API permits one.

This is evidence that the toolchain and patterns can work in one application. It is not general proof of OS-version availability.

## Residual Evidence Boundaries

- The 1.1 versus 1.2 Data Browser wording remains a historical documentation-layer discrepancy. Preserve both statements when discussing old floors; it does not affect the blessed 1.6 target.
- CarbonLib 1.6 is the sourced and blessed native runtime for this skill. Treat any proposed move to a different CarbonLib revision as a separate research and validation decision.
- Universal Interfaces include many Mac OS X-only declarations alongside classic APIs. Check each function's `CarbonLib:` annotation; family or header membership is not evidence.
- Emulator and hardware runs remain required application verification, not desk research. The skill deliberately reports untested targets as untested.
- The exact `GetSharedLibrary` name can vary by service and SDK packaging. Obtain it from the selected SDK or import definition rather than treating the library inventory as a runtime string table.
