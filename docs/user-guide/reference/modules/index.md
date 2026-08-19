---
page_id: module-index-reference
title: Module reference
description: Find every stable module and understand how the macOS host arranges modules into shelves and a drawer.
doc_type: reference
audience: user
lifecycle: current
authority: [docs/module-manifest.yaml, docs/contract-coverage.md, now-host/Sources/Host/NavigationLayout.swift]
source_dependencies: [docs/module-manifest.yaml, now-host/Sources/Host/ModuleRegistry.swift, now-host/Sources/Host/NavigationLayout.swift, now-host/Sources/Host/NavigationSelection.swift, now-host/Sources/Host/HostSidebarView.swift, now-host/Sources/Host/SidebarNavigationContent.swift, now-host/Sources/Host/SidebarNativeDragSurface.swift, now-host/Sources/Host/SidebarCanvasDropHost.swift, now-host/Sources/Host/ShelfDetailView.swift, now-host/Sources/Host/ModuleAvailabilityPresentation.swift, now-host/Sources/Host/AppearancePreferences.swift, now-host/Sources/Host/SettingsWindowController.swift, now-guest-ppc/src/workshop/workshop_module.h, now-guest-68k/src/commands/commands68.c, scripts/docs-inventory, tools/docs-gate]
media_ids: []
last_verified: 2026-08-14
---

<!-- now-doc-provenance: generated reviewed=false -->

# Module reference

## Navigation on the macOS host

Each row in this reference remains a first-class module with a stable identity.
The host groups related modules into **shelves** for navigation; a shelf does
not merge or replace the module implementations inside it. The initial layout
is:

| Area | Shelf or module | Pages |
|---|---|---|
| Upper sidebar | This Mac | Overview, Hardware, Software, Processes, Diagnostics |
| Upper sidebar | Screen | Screen, Mirror |
| Upper sidebar | Files | Files, iCloud |
| Upper sidebar | Chat | Chat |
| Upper sidebar | Development | Development |
| Lower pinned stack | Debug | Console, Logs |
| Lower pinned stack | Connections | Connections, Networking, MCP, Web Proxy |

Each shelf is one sidebar item. Selecting it opens a shelf page with its pages
as centered pill tabs at the top of the main area; the selected module renders
under that strip. The window toolbar chooses the active guest and can collapse
the sidebar to its module icons without changing the saved arrangement. The
sidebar canvas has two stacks: ordinary destinations
grow down from the top, while Debug and then Connections are initially pinned
upward from its bottom, with Connections bottommost. The labeled Drawer is the only destination in
the separate footer beneath that canvas. In Full row mode, a shelf lists its
member modules; a standalone module keeps its own description.

**Overview** is the landing page for the This Mac shelf. It summarizes the
selected classic Mac; it is not another module. When no guest is attached,
that shelf reads **No Mac Connected** without changing the selected page or
the saved layout. **Connections** is also the landing page and visible name of
the Connections shelf.

Drag normally to reorder modules, move them between the upper and lower
stacks, or put them in the drawer at the bottom. Empty sidebar space is also a
drop target: the nearest half chooses the upper or lower stack. Sidebar rows
and a shelf's pill tabs move out of the way as the dragged item crosses their
insertion points; releasing saves that arrangement, while cancelling the drag
restores the saved layout. Dropping one module on another creates a shelf only
when released and immediately opens its editable name,
starting at **New Shelf** (or the next numbered name). Press **Escape** while
that field is active to cancel the shelf and restore both modules to their
previous positions. A user-created shelf
returns to a standalone module
when only one item remains. This Mac is permanent and cannot enter the drawer.
Connections is permanent but can be put away; its live connection dot then
appears on the drawer beside the drawer's module count. The current Screen shelf
contains Screen and Mirror; Continuity is a standalone module beside Mirror
rather than a tab inside that shelf.
Opening a shelf again in the same app session returns to the tab most recently
used in that shelf.

Losing the guest does not remove or navigate away from modules. Host-owned
tools remain usable, cached machine information is marked offline where it can
be shown honestly, and live-only pages offer **Start Listening** or a route to
Connections. Reconnecting restores live behavior in place.

Application appearance is separate from Connections. Choose **New Old World >
Settings…** or press **Command-,** for System, Light, or Dark theme and the
Off, Clear, or Regular Liquid Glass setting. macOS 13–25 and macOS accessibility
settings that reduce transparency or increase contrast use the native material
fallback instead of glass.

| Module | PowerPC Workshop | Pre-Carbon source (excluded from alpha) |
|---|---|---|
| [Screen](screen.md) | Screenshots | supported subset |
| [Files](files.md) | Files | supported subset |
| [iCloud](icloud.md) | iCloud | unavailable |
| [Processes](processes.md) | Processes | supported subset |
| [Mirror](mirror.md) | Mirror | unavailable |
| [Console](console.md) | Console | supported |
| [Chat](chat.md) | Chat | unavailable |
| [Web Proxy](web.md) | guest-loopback relay | unavailable |
| [Hardware](hardware.md) | Hardware | supported subset |
| [Diagnostics](diagnostics.md) | Diagnostics | console-only diagnostics |
| [Networking](networking.md) | Networking | main-window summary |
| [Software](software.md) | Software | supported subset |
| [MCP](mcp.md) | MCP | unavailable |
| [Logs](logs.md) | Logs | console-only evidence |
| [Connections](connections-and-preferences.md) | Preferences + Connection | main window |

This table is a reader-facing projection of the machine-readable module
manifest. Capability coverage and proof remain separate questions; each page
states both. The third column records retained implementation shape for future
work; it does not mean NOW-68K ships in the alpha.

<!-- derived-doc v1
sources: docs/module-manifest.yaml now-host/Sources/Host/ModuleRegistry.swift now-guest-ppc/src/workshop/workshop_module.h now-guest-68k/src/commands/commands68.c scripts/docs-inventory tools/docs-gate
sources-sha1: d8c0bbfdb9abb7fda3078162f7b2f43486087f7b
derive module-map sha256=03dd8a0eabf715800bf6f0c52d475342279647d27fef813faa4a4bb5f4b49062 lines=17
    scripts/docs-inventory
rederived: pending
rederived: 2026-08-09T16:10:26-0400 e74b3ab1 sources, module-map 14->14
rederived: 2026-08-09T16:15:30-0400 e74b3ab1 sources
rederived: 2026-08-09T16:22:21-0400 9034e3eb sources
rederived: 2026-08-09T16:29:42-0400 9034e3eb sources
rederived: 2026-08-09T17:05:28-0400 446cf620 sources
rederived: 2026-08-09T17:08:04-0400 446cf620 sources
rederived: 2026-08-09T17:53:28-0400 ed9436c0 sources
rederived: 2026-08-09T18:53:52-0400 181db7a5 sources
rederived: 2026-08-09T18:56:23-0400 181db7a5 unchanged
rederived: 2026-08-09T19:21:55-0400 dc5bfcd2 sources
rederived: 2026-08-09T19:33:56-0400 c854246d sources
rederived: 2026-08-09T20:56:36-0400 9864da82 sources
rederived: 2026-08-09T21:05:28-0400 9864da82 sources
rederived: 2026-08-09T21:43:47-0400 2b3c2c0e sources
rederived: 2026-08-09T22:09:30-0400 d54812c2 sources
rederived: 2026-08-09T22:18:49-0400 e637efd3 sources
rederived: 2026-08-10T03:07:05-0400 9cbb4c28 unchanged
rederived: 2026-08-10T03:08:47-0400 9cbb4c28 unchanged
rederived: 2026-08-10T03:11:42-0400 9cbb4c28 unchanged
rederived: 2026-08-10T03:46:37-0400 68d74d72 unchanged
rederived: 2026-08-10T02:53:59-0400 62603174 sources, module-map 14->15
rederived: 2026-08-10T02:54:45-0400 62603174 unchanged
rederived: 2026-08-10T04:18:15-0400 423ef214 unchanged
rederived: 2026-08-10T04:49:22-0400 cd585106 unchanged
rederived: 2026-08-10T04:27:16-0400 886ee556 unchanged
rederived: 2026-08-10T04:38:54-0400 886ee556 unchanged
rederived: 2026-08-10T05:38:07-0400 a0ede9ec unchanged
rederived: 2026-08-10T13:37:38-0400 2f62ec11 unchanged
rederived: 2026-08-10T13:51:46-0400 f4a92045 unchanged
rederived: 2026-08-10T14:07:45-0400 b22898ee unchanged
rederived: 2026-08-10T13:10:56-0400 47bf54fb unchanged
rederived: 2026-08-10T13:36:45-0400 b15b4827 unchanged
rederived: 2026-08-10T14:32:11-0400 e75a07a0 sources, module-map 15->16
rederived: 2026-08-10T14:49:44-0400 4ea2d97d sources, module-map 16->16
rederived: 2026-08-10T14:20:14-0400 9e432b8b unchanged
rederived: 2026-08-10T15:11:52-0400 eb9d991c unchanged
rederived: 2026-08-10T15:34:28-0400 72868e9e unchanged
rederived: 2026-08-10T15:52:47-0400 77329146 unchanged
rederived: 2026-08-10T16:52:02-0400 d77cc444 unchanged
rederived: 2026-08-10T20:03:22-0400 d3e26c39 unchanged
rederived: 2026-08-10T20:22:53-0400 818c1577 unchanged
rederived: 2026-08-10T21:35:35-0400 a79833e9 unchanged
rederived: 2026-08-10T22:32:24-0400 e9bf9632 unchanged
rederived: 2026-08-10T22:33:05-0400 e9bf9632 sources
rederived: 2026-08-10T22:47:49-0400 431e7308 unchanged
rederived: 2026-08-11T00:25:05-0400 bbab04b9 unchanged
rederived: 2026-08-11T00:33:22-0400 4b24cc1f unchanged
rederived: 2026-08-11T19:45:15-0400 065da692 sources
rederived: 2026-08-11T20:08:53-0400 852b41ae sources
rederived: 2026-08-11T20:43:59-0400 5c07bcd6 sources
rederived: 2026-08-11T20:54:11-0400 f9ceab81 sources
rederived: 2026-08-11T21:13:10-0400 098805ff sources
rederived: 2026-08-11T21:20:51-0400 15514cc9 sources
rederived: 2026-08-11T21:26:23-0400 7bfb617b sources
rederived: 2026-08-11T21:32:39-0400 57a081ab sources
rederived: 2026-08-11T21:39:37-0400 5a82bf82 sources
rederived: 2026-08-11T21:49:35-0400 7dc5b09d sources
rederived: 2026-08-11T21:54:55-0400 8c482312 sources
rederived: 2026-08-11T21:59:53-0400 562b4b50 sources
rederived: 2026-08-11T22:06:35-0400 65f52bf3 sources
rederived: 2026-08-11T22:10:48-0400 3df65dde sources
rederived: 2026-08-11T22:15:20-0400 68853632 sources
rederived: 2026-08-11T22:31:04-0400 a16b6a61 sources
rederived: 2026-08-11T22:41:39-0400 e1fc84c4 sources
rederived: 2026-08-11T22:47:34-0400 9776cf7a sources
rederived: 2026-08-11T22:56:41-0400 2401cdb7 sources
rederived: 2026-08-11T23:03:13-0400 496fd2cd sources
rederived: 2026-08-11T23:10:57-0400 ddf740ce sources
rederived: 2026-08-11T23:12:01-0400 ddf740ce unchanged
rederived: 2026-08-11T23:31:22-0400 ad4d680 sources
rederived: 2026-08-11T23:37:12-0400 ad4d680 unchanged
rederived: 2026-08-12T13:02:41-0400 7cea759e sources
rederived: 2026-08-12T13:11:34-0400 7cea759e unchanged
rederived: 2026-08-12T13:12:13-0400 7cea759e unchanged
rederived: 2026-08-12T15:54:08-0400 939e43b7 unchanged
rederived: 2026-08-12T17:19:20-0400 338eca21 unchanged
rederived: 2026-08-12T18:34:29-0400 3688b9f6 unchanged
rederived: 2026-08-12T18:58:27-0400 3771e144 unchanged
rederived: 2026-08-12T19:15:24-0400 3771e144 unchanged
rederived: 2026-08-12T19:31:58-0400 3771e144 unchanged
rederived: 2026-08-12T20:08:32-0400 5a601a18 unchanged
rederived: 2026-08-12T20:15:22-0400 9e828cdc unchanged
rederived: 2026-08-12T20:34:42-0400 4d9ba67d unchanged
rederived: 2026-08-12T20:37:08-0400 633da491 unchanged
rederived: 2026-08-12T20:45:46-0400 a0878023 unchanged
rederived: 2026-08-12T22:18:37-0400 18d0d3c4 unchanged
rederived: 2026-08-12T23:59:07-0400 e5b16a71 unchanged
rederived: 2026-08-13T00:21:46-0400 e5b16a71 unchanged
rederived: 2026-08-13T00:58:13-0400 9f5139cf unchanged
rederived: 2026-08-13T01:23:45-0400 9f5139cf unchanged
rederived: 2026-08-13T01:47:13-0400 59852197 unchanged
rederived: 2026-08-13T02:45:49-0400 e504061c unchanged
rederived: 2026-08-13T04:30:01-0400 47f632b3 unchanged
rederived: 2026-08-13T13:50:55-0400 a9e64fa4 unchanged
rederived: 2026-08-13T14:32:32-0400 4da9c4a3 unchanged
rederived: 2026-08-13T15:15:23-0400 2ccde05b unchanged
rederived: 2026-08-13T17:36:05-0400 043777df unchanged
rederived: 2026-08-13T17:37:43-0400 043777df unchanged
rederived: 2026-08-13T18:23:47-0400 e6d7996d unchanged
rederived: 2026-08-13T19:30:44-0400 1d154b67 unchanged
rederived: 2026-08-13T21:59:04-0400 8433efda unchanged
rederived: 2026-08-13T23:16:02-0400 fc235d4e unchanged
rederived: 2026-08-14T00:51:51-0400 94f1c614 unchanged
rederived: 2026-08-14T00:55:48-0400 3bd83df2 unchanged
rederived: 2026-08-14T02:20:51-0400 81247e50 unchanged
rederived: 2026-08-14T03:25:52-0400 ee8ef8a4 unchanged
rederived: 2026-08-14T03:54:49-0400 d016e771 unchanged
rederived: 2026-08-14T03:57:09-0400 e122c6c3 unchanged
rederived: 2026-08-14T04:03:19-0400 908215de unchanged
rederived: 2026-08-14T04:36:35-0400 e66db808 unchanged
rederived: 2026-08-14T12:32:39-0400 7742eab5 sources
rederived: 2026-08-14T12:35:45-0400 49e6dd98 unchanged
rederived: 2026-08-14T12:44:43-0400 4d52ba1a unchanged
rederived: 2026-08-14T12:47:23-0400 804be291 unchanged
rederived: 2026-08-14T12:49:06-0400 655b2bf1 unchanged
rederived: 2026-08-14T13:16:43-0400 90cfd8fa sources
rederived: 2026-08-14T14:27:58-0400 6d037a57 sources, module-map 16->17
rederived: 2026-08-14T15:56:44-0400 835e6acf unchanged
rederived: 2026-08-14T16:58:28-0400 cf962dbb unchanged
rederived: 2026-08-14T17:12:28-0400 32ac9165 unchanged
rederived: 2026-08-14T17:36:04-0400 02e9de5e unchanged
rederived: 2026-08-14T18:14:39-0400 db6a7c6a unchanged
rederived: 2026-08-14T18:17:42-0400 d9ed70d2 unchanged
rederived: 2026-08-14T18:19:51-0400 60bb3427 unchanged
rederived: 2026-08-14T18:20:42-0400 23dc0759 unchanged
rederived: 2026-08-14T18:22:07-0400 23dc0759 unchanged
rederived: 2026-08-14T18:23:12-0400 e2c66126 unchanged
rederived: 2026-08-14T18:30:53-0400 b248c9a1 unchanged
rederived: 2026-08-14T18:31:12-0400 b248c9a1 unchanged
rederived: 2026-08-14T18:31:26-0400 b248c9a1 unchanged
rederived: 2026-08-14T19:50:32-0400 d20eee81 unchanged
rederived: 2026-08-14T19:50:54-0400 d20eee81 unchanged
rederived: 2026-08-14T20:02:53-0400 068ca7fd unchanged
rederived: 2026-08-14T21:00:58-0400 ab304cb2 unchanged
rederived: 2026-08-14T21:15:09-0400 5316a23e unchanged
rederived: 2026-08-14T23:07:32-0400 9d85a31d unchanged
rederived: 2026-08-15T00:30:15-0400 f4dab407 unchanged
rederived: 2026-08-15T01:11:36-0400 c9a1a8a4 unchanged
rederived: 2026-08-15T03:16:30-0400 2c7ff2a1 unchanged
rederived: 2026-08-15T03:17:33-0400 2c7ff2a1 unchanged
rederived: 2026-08-15T03:18:50-0400 2c7ff2a1 unchanged
rederived: 2026-08-15T04:01:11-0400 b18a891c unchanged
rederived: 2026-08-15T12:33:03-0400 eadb1784 unchanged
rederived: 2026-08-15T13:22:25-0400 4e897bc6 unchanged
rederived: 2026-08-15T14:24:09-0400 599da71e unchanged
rederived: 2026-08-15T14:56:50-0400 4caf46ef unchanged
rederived: 2026-08-15T15:01:59-0400 a06d9396 unchanged
rederived: 2026-08-15T15:16:39-0400 cc0d429b unchanged
rederived: 2026-08-15T15:19:24-0400 658719b4 unchanged
rederived: 2026-08-15T15:25:08-0400 7949e13a unchanged
rederived: 2026-08-15T16:00:10-0400 69217d7a unchanged
rederived: 2026-08-15T16:06:11-0400 69217d7a unchanged
rederived: 2026-08-15T16:43:48-0400 919bcc60 unchanged
rederived: 2026-08-15T18:06:56-0400 feaa6945 unchanged
rederived: 2026-08-15T19:13:28-0400 ce43eb74 unchanged
rederived: 2026-08-15T22:25:52-0400 f627b5b4 unchanged
rederived: 2026-08-16T13:07:44-0400 3fff0d5e unchanged
rederived: 2026-08-16T13:48:35-0400 abfb91b7 unchanged
rederived: 2026-08-16T14:23:14-0400 8e68ec3a unchanged
rederived: 2026-08-16T14:56:45-0400 3eac8061 unchanged
rederived: 2026-08-16T15:14:03-0400 3eac8061 unchanged
rederived: 2026-08-16T15:40:24-0400 484f1ecd unchanged
rederived: 2026-08-16T15:51:39-0400 3c9b1213 unchanged
rederived: 2026-08-16T16:01:12-0400 5e83598e unchanged
rederived: 2026-08-16T16:13:00-0400 d9f3bb77 unchanged
rederived: 2026-08-16T16:57:26-0400 49fcbc64 sources, module-map 17->17
rederived: 2026-08-16T18:23:18-0400 1162e33a unchanged
rederived: 2026-08-16T18:52:31-0400 51558682 unchanged
rederived: 2026-08-16T19:17:53-0400 0c75216b unchanged
rederived: 2026-08-16T21:38:02-0400 9e1756d6 unchanged
rederived: 2026-08-16T22:00:22-0400 c578fc99 unchanged
rederived: 2026-08-16T23:39:05-0400 eecd0c30 unchanged
rederived: 2026-08-17T02:09:48-0400 f94e2762 unchanged
rederived: 2026-08-17T03:31:09-0400 8cf43bb9 unchanged
rederived: 2026-08-17T14:41:18-0400 e7b68a20 unchanged
rederived: 2026-08-17T15:49:23-0400 6c899380 unchanged
rederived: 2026-08-17T15:52:53-0400 6c899380 unchanged
rederived: 2026-08-17T16:04:36-0400 ef984b29 unchanged
rederived: 2026-08-17T16:17:03-0400 f60e2999 unchanged
rederived: 2026-08-17T18:04:09-0400 30e23df6 unchanged
rederived: 2026-08-17T18:09:10-0400 4fb9b6b0 unchanged
rederived: 2026-08-17T18:50:31-0400 e18796a5 unchanged
rederived: 2026-08-17T23:36:26-0400 5aa1092c unchanged
rederived: 2026-08-17T23:52:46-0400 91fe237e unchanged
rederived: 2026-08-18T15:09:50-0400 c33eb6ee unchanged
rederived: 2026-08-18T17:19:00-0400 ffc561f4 unchanged
rederived: 2026-08-18T21:43:39-0400 eae627f6 unchanged
rederived: 2026-08-18T23:04:15-0400 fc295bcc unchanged
rederived: 2026-08-18T23:13:33-0400 ce4dc746 unchanged
rederived: 2026-08-18T23:19:31-0400 3341acb1 sources
rederived: 2026-08-18T23:25:22-0400 353a37be unchanged
rederived: 2026-08-18T23:33:03-0400 2c64a5c4 unchanged
rederived: 2026-08-18T23:44:45-0400 6692e45b unchanged
rederived: 2026-08-18T23:57:03-0400 d10402f4 unchanged
rederived: 2026-08-19T00:06:06-0400 b3b2ee57 unchanged
rederived: 2026-08-19T01:21:59-0400 0e46a4ac unchanged
rederived: 2026-08-19T01:34:47-0400 7ec2d6d1 unchanged
rederived: 2026-08-19T01:41:13-0400 399d4c78 unchanged
rederived: 2026-08-19T01:53:16-0400 db827bac unchanged
rederived: 2026-08-19T02:32:04-0400 a9efa24f unchanged
rederived: 2026-08-19T03:00:30-0400 26f5c9fc unchanged
rederived: 2026-08-19T03:14:02-0400 afcf45e6 unchanged
rederived: 2026-08-19T03:33:52-0400 648ab89c unchanged
rederived: 2026-08-19T03:53:11-0400 f9d1bd67 unchanged
rederived: 2026-08-19T03:59:56-0400 14486719 unchanged
rederived: 2026-08-19T04:47:57-0400 ba4e78ae unchanged
rederived: 2026-08-19T05:41:22-0400 a8ee7d50 unchanged
rederived: 2026-08-19T14:24:10-0400 d6583bbd unchanged
rederived: 2026-08-19T14:49:25-0400 75da2302 unchanged
-->
