---
page_id: optional-extension-explanation
title: Core features and the NOW Extension
description: See which initial-alpha features work in the normal application, which need the optional NOW Extension, and which remain experimental.
doc_type: explanation
audience: user
lifecycle: current
authority: [docs/feature-catalog.yaml, docs/status.md, docs/user-guide/reference/limitations.md]
source_dependencies: [docs/feature-catalog.yaml, docs/status.md, docs/user-guide/reference/limitations.md, docs/module-manifest.yaml, docs/resident-components.md, contract/peek_table.h]
media_ids: []
last_verified: 2026-08-09
feature_ids: [resident.extension]
---

# Core features and the NOW Extension

Start with the normal PowerPC application. It connects, transfers files,
captures the screen, reports processes and machine details, and provides the
Workshop without installing anything in the classic Mac's Extensions folder.

The optional **NOW Extension** is for deeper Mirror features. It lets NOW
observe and interact while another classic application is drawing, tracking a
drag, showing a menu, or holding the machine inside a modal loop. Installing it
does not replace the application or unlock ordinary connection, file, screen,
console, process, hardware, or software features.

## Feature coverage

<!-- extension-feature-matrix -->

**Included** rows are part of the initial-alpha PowerPC path, subject to the
linked limitations. **Experimental** rows are available for evaluation but do
not carry the same release confidence. Emulator-verified or tested rows have
not necessarily been observed on physical hardware.

## Decide whether to install it

- Skip it when you want the normal NOW connection, file, screen, inventory, or
  console experience.
- Install it when you are deliberately evaluating the Extension-required
  Mirror rows in the matrix and can recover by booting with Extensions
  disabled.
- Leave structured drawing capture off unless you are working on that
  experimental path; it remains the highest-risk Extension feature.

The application reports whether the Extension is absent, active, incompatible,
or waiting for a restart. It also reports the capabilities the installed build
actually negotiated; the matrix does not override that live state.

## How it fits together

The Extension runs only the small amount of work that must occur inside another
classic process. The normal application remains the network endpoint and reads
the Extension's bounded state later. Removing the Extension returns NOW to the
application-only coverage shown above.

For installation and recovery, see [Install the NOW
Extension](../how-to/install-extension.md). Developers looking for the P0–P8
contract and capability-bit mapping should use [Resident
components](../../developer-guide/architecture/resident-components.md); those
implementation details are deliberately not the primary user-facing feature
list.
