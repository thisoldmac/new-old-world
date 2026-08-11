---
page_id: set-up-new-mac-how-to
title: Set up a new PowerPC Mac
description: Use the macOS host to build and serve a personalized, fork-preserving setup disk to a PowerPC Mac.
doc_type: how-to
audience: user
lifecycle: current
authority: [docs/onboarding.md]
source_dependencies: [docs/onboarding.md, now-host/Sources/Host/OnboardingPortal.swift, now-host/Sources/Host/OnboardingPage.swift, now-host/Sources/Host/ClassicSetupImageBuilder.swift, now-host/Sources/Host/OnboardingAssets.swift]
media_ids: [setup-onboarding-host, setup-onboarding-browser, setup-onboarding-disk]
last_verified: 2026-08-09
feature_ids: [classic.powerpc, resident.extension]
---

# Set up a new PowerPC Mac

Use **Set Up a New Mac** when the classic Mac has a web browser and Disk Copy
6.3.3 but does not yet have NOW. The host builds one personalized setup disk,
preserves classic file forks, and serves it from a deliberately simple page.

!!! warning "Current verification boundary"
    The host flow is tested locally, and its image mounts in a Mac OS 9.1 QEMU
    guest. Downloading it through a classic browser and reaching the first
    physical-hardware connection have not yet been verified end to end.

## 1. Start setup on the modern Mac

Open **Connections**, choose **Set Up a New Mac…**, and confirm the address and
port shown in the sheet. Both Macs must be on the same trusted local network.

![Set Up a New Mac showing the reachable address and selected packages](../../assets/screenshots/getting-started/onboarding-host.svg){ .now-placeholder }

## 2. Choose the setup contents

The New Old World application and generated preferences are required. The
bundled **NOW Extension is optional**: select it only if you want the deeper
Mirror features in [Core features](../explanation/core-features.md) and can
recover by starting with Extensions disabled. Select any dependency only when
the setup sheet identifies it and accepts the available package.

Build or rebuild the image after changing a selection. Check the displayed
contents and size before offering it to the other Mac.

## 3. Download the complete setup disk

In the classic Mac's browser, open the exact `http://…/now` address shown by
the host. Choose the complete setup disk. If the browser cannot preserve the
download directly, use the `.bin` link and allow the classic transfer software
to decode its MacBinary envelope.

![The classic-browser setup page and complete setup disk link](../../assets/screenshots/getting-started/onboarding-browser.svg){ .now-placeholder }

The setup server supports the narrow, old-browser-compatible GET and HEAD
paths shown on that page. It does not accept uploads or expose a directory
listing.

## 4. Open and install

Open the downloaded image with **Disk Copy 6.3.3**. Copy **New Old World** to
the classic Mac. Put **New Old World Prefs** in **System Folder:Preferences**.
If you selected the Extension, put it in **System Folder:Extensions** and
restart before expecting its features.

![The mounted NOW Setup disk with its selected contents](../../assets/screenshots/getting-started/onboarding-disk.svg){ .now-placeholder }

## 5. Prove the connection

Launch New Old World. The generated preferences already contain the host
address and listener port. Setup is complete only when the host shows a named
active session and a module returns a typed result; a successful download is
not connection evidence.

Stop the onboarding server when setup is complete. It is temporary plaintext
HTTP intended only for a trusted LAN.

## If setup stops

- A missing required package or rejected checksum leaves the image unavailable;
  replace or reacquire that package rather than bypassing the check.
- Selections changed after the last build require a new image.
- If the browser mishandles the disk image, use the offered MacBinary form and
  confirm the transfer software decoded it.
- If archive extraction support is unavailable on the host, install the named
  local prerequisite or provide an already accepted package.
- If the guest cannot connect, use [Recover a connection](recover-a-connection.md).

For a manual fallback, use [Install the PowerPC guest](install-ppc.md) and
[Configure a connection](configure-connection.md).
