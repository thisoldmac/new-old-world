---
title: Host module shelves, drawer, settings, and disconnected state
type: feat
date: 2026-08-13
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
---

<!-- now-doc-provenance: generated reviewed=false -->

# Host module shelves, drawer, settings, and disconnected state

## Goal Capsule

Rebuild the native macOS host's navigation around first-class modules that a
person can arrange as standalone rows or shelves, move between upper and lower
sidebar regions, and put away in a drawer. Add an actual Settings window for
appearance, use Liquid Glass as native chrome where the runtime supports it,
and make connection loss an honest reduced state rather than a broken shell.

This is a host-first proof. It does not change the guest Workshop, the wire
contract, or synchronize layouts over the wire yet.

## Product decisions

- Every registered module remains a first-class leaf with a stable identifier.
- A shelf is navigation composition, not a replacement implementation module.
- Dropping one module on another creates a user shelf. A user shelf decomposes
  when only one module remains.
- The machine shelf and Network shelf are permanent and do not decompose.
- The machine shelf cannot enter the drawer. Network can.
- The machine shelf's hero is an Overview page, not a draggable pseudo-module.
- Network's hero is the existing Connections module (`settings` remains its
  stable historical identifier).
- `web` remains the stable identifier and is presented as **Web Proxy**.
- Ordinary drag is sufficient; there is no modifier-drag behavior.
- A valid combine or drawer target spring-loads after a short dwell, then
  flashes twice. No mutation occurs before the drop.
- The drawer's number is its contained module count. If Network is stored, its
  connection-status dot follows it to the drawer as a separate accessory.
- The host and guest may later offer opt-in layout synchronization once per
  accepted hello/session epoch, never on heartbeat. That later behavior starts
  in `contract/asyncapi.yaml`; this plan only leaves a serializable seam.

## Default layout

| Zone | Item | Hero and tabs |
|---|---|---|
| Upper | `{Guest Name}` | Overview; Hardware, Software, Processes, Diagnostics |
| Upper | Screen | Screen, Mirror |
| Upper | Files | Files, iCloud |
| Upper | Chat | standalone |
| Upper | Development | standalone |
| Lower | Network | Connections; Networking, MCP, Web Proxy |
| Lower | Console | standalone |
| Lower | Logs | standalone |
| Drawer | empty | — |

When no guest is attached, the machine shelf reads **No Mac Connected** while
retaining its stable shelf identity and selection.

Continuity is deliberately absent from the current registry. The Screen shelf
must adopt a real `continuity` module automatically when that descriptor lands;
this work does not create a placeholder or modify Mirror-owned functionality.

## Active-lane integration contract

### Files

The Files modernization branch `codex/files-module-modernization` at
`ef33ce26` is an input to this work. Preserve its owned files and the existing
shell entry point:

```swift
FilesModuleView(model: state.files)
```

The shell may route and embed Files but does not edit `FilesModuleView.swift`,
`FilesModel.swift`, `FileBrowserTable.swift`, `FileLocationRow.swift`, or
`FilesWorkspaceViews.swift`.

### Mirror and Continuity

Preserve the stable `mirror` identifier and the current
`MirrorModuleView`/`NOWMirrorSource` APIs. Keep navigation ownership outside
Mirror files. If the active Continuity integration changes `HostRootView`,
`ModuleRegistry`, or module registration, reconcile that shared seam explicitly
before final verification. A breaking signature change requires notifying the
Files and Continuity lanes before it is made.

## Compatibility contract

The project keeps its macOS 13 deployment floor.

| Tier | Navigation drag | Chrome | Appearance |
|---|---|---|---|
| macOS 27 | AppKit native path; SDK 27 reorder APIs are not required | Liquid Glass | System/Light/Dark |
| macOS 26 | AppKit native path | Liquid Glass | System/Light/Dark |
| macOS 14–25 | AppKit native path | material fallback; symbol pulse available | System/Light/Dark |
| macOS 13 | AppKit native path | material and AppKit animation fallback | System/Light/Dark |
| Reduce Transparency or Increase Contrast | unchanged | material fallback | chosen scheme retained |

The Xcode 27 SDK exposes `Glass.identity`, `Glass.clear`, and `Glass.regular`,
not a continuous intensity scalar. The Settings slider therefore has three
detents: Off/Material, Clear, and Regular. Regular preserves today's default.

## Disconnected-state contract

Disconnection must not navigate, erase the layout, remove modules, or show a
modal alert.

- **Local:** Connections, Logs, MCP, Web Proxy configuration, iCloud
  configuration, and local Chat/Development state remain available.
- **Reduced:** useful last-known captures or inventory may remain visible with
  the guest name and observation time; mutation is unavailable.
- **Unavailable:** live-only guest actions show a shared explanation and route
  to Connections or Start Listening where applicable.
- Reconnection rebinds the selected module in place.
- Existing module cache lifetime remains authoritative. The shell does not
  independently clear or retain module data.

## Scope boundaries

- No guest UI implementation or Carbon drag changes.
- No layout messages in the wire contract.
- No edits to Files-owned or Mirror/Continuity-owned feature internals.
- No placeholder Continuity page.
- No relocation of connection, provider, sidebar, or module-specific settings
  into the Settings window beyond Theme and Liquid Glass.
- No deployment-target increase and no SwiftUI App-lifecycle migration.

## Verification Contract

| Gate | Required evidence |
|---|---|
| Layout domain | Focused tests prove every known module appears exactly once after migration/sanitization and special-shelf invariants hold |
| Persistence | Focused tests prove legacy order migration, corrupt-state repair, renames, relaunch persistence, and new-module adoption |
| Navigation | Tests prove shelf/tab selection and View-menu routing; host build proves every descriptor has a detail route |
| Drag | Pure drop-decision tests cover cross-zone moves, combine, extraction, invalid drops, decomposition, and drawer count |
| Disconnection | Pure presentation tests cover local, reduced, unavailable, disconnect, and reconnect without selection movement |
| Settings | Tests prove theme/glass persistence and Settings-window singleton/menu routing |
| Compatibility | Builds with Xcode 27 SDK at macOS 13 target; runtime availability is centralized and a forced fallback is testable |
| Integration | `scripts/test-host`, then `scripts/test-all` |
| Visual | Inspect default window, collapsed sidebar, drawer, Settings, light/dark, disconnected state, and Reduce Transparency fallback |

New guards must be watched failing against the mutation they claim to catch.

## Implementation Units

### U1. Establish the versioned layout domain

**Goal:** Replace flat placement/order with typed first-class modules, shelves,
zones, and a serializable layout whose invariants are pure and testable.

**Files:** `ModuleRegistry.swift`, new `NavigationLayout.swift`, new
`NavigationLayoutStore.swift`, `SidebarPreferences.swift`, focused tests.

**Approach:** Keep registry descriptors immutable. Store only stable IDs and
user shelf metadata. Sanitize into a total partition of the current registry.
Special shelves have fixed IDs and hero policy; user shelves have UUID-backed
IDs. Derive drawer counts and status location rather than persisting them.

**Execution note:** Proof-first. Write invariant/migration tests and observe
the old flat model fail them before production implementation.

**Verification:** Focused layout and sidebar preference tests.

### U2. Add the native Settings window and appearance model

**Goal:** Make `Command-,` open one separate Settings window containing Theme
and the detented Liquid Glass preference.

**Files:** `App.swift`, `MainMenu.swift`, `GlassStyle.swift`, new
`AppearancePreferences.swift`, new `SettingsWindowController.swift`, new
`HostSettingsView.swift`, focused tests.

**Approach:** Retain the AppKit lifecycle. Cache one window controller. Apply
System/Light/Dark through `NSApp.appearance` before the main window is created.
Keep effective glass selection and accessibility/runtime fallback behind the
existing centralized glass vocabulary.

**Execution note:** Test persistence and menu/window ownership first; visual
glass behavior uses build plus manual inspection rather than snapshot claims.

**Verification:** Focused appearance/menu tests and Debug/Release host builds.

### U3. Render shelves and route details

**Goal:** Render the accepted upper/lower default, machine Overview hero,
Network Connections hero, detail-pane pill tabs, and stable module selection.

**Files:** `HostRootView.swift`, new navigation subviews, new
`MachineOverviewView.swift`, `MainMenu.swift`, registry/menu tests.

**Approach:** Split the current root into real View types with narrow inputs.
Selection distinguishes a shelf hero from a module leaf. View-menu module
selection reveals its shelf and tab. Each shelf is one native sidebar-list row;
its member modules are centered pills above the selected module in the detail
pane. Network, Console, Logs, and the labeled Drawer form one compact pinned
utility area. Preserve each module's existing entry point; specifically
preserve Files and Mirror signatures.

**Execution note:** Characterize current selection restoration before changing
the shell, then strengthen it for shelf/tab navigation.

**Verification:** Focused registry, app-state, menu, and selection tests.

### U4. Add native drag, shelf composition, and the drawer

**Goal:** Support ordinary cross-zone drag, drop-to-shelf, tab extraction,
spring-loaded targets, user-shelf decomposition, and drawer accessories.

**Files:** new `SidebarNativeDragSurface.swift`, new
`NavigationDragCoordinator.swift`, new `ModuleDrawerView.swift`, navigation
views, focused tests.

**Approach:** Use AppKit dragging and spring-loading at the macOS 13 floor.
Keep all mutations as pure layout commands decided by the coordinator. Dwell
and double-flash are feedback only; the drop commits the command. Use SF Symbol
effects where available and an AppKit animation fallback on 13. Snapshot the
rendered row or detail pill for the native drag preview.

**Execution note:** Proof-first for every layout command and invalid target.
Native gesture timing receives a manual interaction check.

**Verification:** Focused drag/layout tests plus interactive host inspection.

### U5. Unify graceful disconnected presentation

**Goal:** Keep the shell usable when the guest disconnects and give every
guest-dependent surface an honest local/reduced/unavailable presentation.

**Files:** new `ModuleAvailabilityPresentation.swift`, new shared disconnected
views/banners, `HostRootView.swift`, module integration points outside Files and
Mirror ownership, focused tests.

**Approach:** Derive presentation from connection state and module policy. Do
not duplicate cache lifetime. Keep selection unchanged across disconnect and
reconnect. Route recovery actions to the Network shelf's Connections hero.

**Execution note:** Test the pure policy first, then wire only shell-owned
presentation. Preserve existing richer module-specific disconnected states.

**Verification:** Focused policy/app-state tests and forced disconnect/reconnect
inspection.

### U6. Reconcile active lanes, documentation, and gates

**Goal:** Integrate the current Files and Continuity outcomes, update derived
module documentation, and close the host verification matrix.

**Files:** module manifest/pages and tests required by live changes; no active
lane internals unless their owner has explicitly handed over the seam.

**Approach:** Rebase/merge the accepted lane heads, inspect actual conflicts,
and rederive rather than hand-edit generated coverage. Add Continuity to the
Screen shelf only if a real registry descriptor is now present.

**Execution note:** Re-run derivations after the final merge. A clean textual
merge is not evidence.

**Verification:** `scripts/test-host`, `scripts/test-all`, docs gate when
required, and compatibility/visual matrix.

## Definition of Done

- The accepted default layout renders and persists from a versioned model.
- All current registry modules appear exactly once and preserve stable IDs.
- User shelves, upper/lower movement, the drawer, and decomposition operate
  through ordinary native drag.
- This Mac and Network special-shelf rules are enforced.
- Network's status dot follows the shelf into the drawer.
- Disconnection preserves the shell and communicates local, reduced, and
  unavailable behavior without dead controls or forced navigation.
- `Command-,` opens a separate singleton Settings window with immediate
  System/Light/Dark and Off/Clear/Regular glass preferences.
- Liquid Glass is used only for appropriate chrome on macOS 26+, with an
  explicit macOS 13–25 and accessibility fallback.
- Files and Mirror/Continuity active-lane boundaries are preserved or their
  owners were notified before a breaking change.
- Required focused and repository gates pass, and unverified runtime cells are
  named rather than described as working.
