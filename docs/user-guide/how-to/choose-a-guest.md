---
page_id: choose-guest-how-to
title: Choose the right guest
description: Select the PowerPC Carbon guest or NOW-68K from the actual operating-system and network requirements.
doc_type: how-to
audience: user
lifecycle: current
authority: [README.md, docs/naming.md]
source_dependencies: [now-guest-ppc/CMakeLists.txt, now-guest-68k/CMakeLists.txt, now-host/Package.swift]
media_ids: []
last_verified: 2026-08-09
---

# Choose the right guest

## Goal

Choose one guest artifact without treating the 68K build as a smaller port of
the PowerPC Workshop.

## Steps

1. If the classic Mac runs Mac OS 8.6–9.2.2, is PowerPC, and has CarbonLib
   1.6, choose **New Old World.bin**, the PowerPC Carbon guest.
2. If the target is the current 68K System 7.1/MacTCP rig, choose
   **now-guest-68k.bin**.
3. If neither statement describes the machine, stop. The current pre-alpha
   does not claim a supported guest for it.
4. Read [Guests and compatibility](../explanation/guests-and-compatibility.md)
   before assuming the two guests expose identical UI or modules.

## Expected result

The chosen artifact launches in its native application model: one Workshop on
PowerPC, or the compact main window plus console on 68K.

## Recovery

If a PowerPC build refuses to launch, check the CarbonLib version before
changing network settings. If NOW-68K cannot dial, verify MacTCP and the host
address; Open Transport instructions do not apply to that build.
