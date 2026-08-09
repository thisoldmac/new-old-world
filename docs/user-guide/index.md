---
page_id: user-guide-home
title: User guide
description: Install, connect, operate, and recover New Old World without adopting the contributor build workflow.
doc_type: tutorial
audience: user
lifecycle: current
authority: [README.md, SECURITY.md]
source_dependencies: [README.md, SECURITY.md, docs/module-manifest.yaml]
media_ids: []
last_verified: 2026-08-09
---

# User guide

Use this guide when you want to run NOW, not build it.

1. Follow [Connect your first classic Mac](tutorials/first-connection.md).
2. Review [core features](explanation/core-features.md) to see what works in
   the normal app and which experimental features need the bundled, optional
   NOW Extension.
3. Check the [alpha feature profile](reference/release-profile.md).
4. Use the [how-to guides](how-to/choose-a-guest.md) for one concrete task.
5. Open the [module reference](reference/modules/index.md) for controls,
   availability, failure states, and limitations.
6. Read the [explanations](explanation/two-macs-one-contract.md) when you need
   the product model behind a behavior.

The alpha uses the PowerPC Carbon guest. NOW-68K/pre-Carbon support is retained
for future work but is excluded from the release bundle.

NOW is a pre-alpha tool for a trusted local network. Its classic wire is
plaintext and unauthenticated. Do not expose the listener to the internet.
