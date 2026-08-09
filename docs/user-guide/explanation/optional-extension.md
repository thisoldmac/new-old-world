---
page_id: optional-extension-explanation
title: The optional NOW Extension
description: Why the PowerPC resident exists, what it may observe, and why NOW must remain useful without it.
doc_type: explanation
audience: user
lifecycle: experimental
authority: [contract/peek_table.h, docs/resident-components.md, docs/feature-catalog.yaml]
source_dependencies: [docs/resident-components.md, contract/peek_table.h, ext, docs/feature-catalog.yaml]
media_ids: []
last_verified: 2026-08-09
feature_ids: [resident.extension]
---

# The optional NOW Extension

The NOW Extension is the optional component that turns Mirror from ordinary
application-level inspection into process-local observation and interaction.
It ships as one classic Mac OS extension, loads at startup, and exposes a
versioned set of independently negotiated planes to the PowerPC guest.

Some classic Macintosh facts exist only while another application is drawing
or handling events. The optional resident can observe those moments and publish
bounded state through one versioned in-memory table. The normal application
reads the table later; the host still communicates with the application over
the ordinary wire.

That ownership boundary is strict: foreign-context execution stays in the
resident, foreign-memory reads stay in the application, and the shared layout
lives once in `contract/peek_table.h`. The resident does not become a second
network stack or a required service.

## What the extension adds

<!-- extension-capability-table -->

The list is derived from `docs/feature-catalog.yaml`, and the documentation gate
checks its capability symbols against every `kNowPeekTableCap*` bit in
`contract/peek_table.h`. P0 is the discovery core and therefore has no plane
bit. P6 deliberately owns two bits: one says the liveness vehicle exists and
one says the resident can open the network transport.

The table describes what the current source exposes, not a blanket statement
of hardware verification. A running extension publishes its actual capability
word, formats, active planes, and evidence; the app must believe those values
rather than the product version or this page.

## What still works without it

Without the extension, Files, Processes, Screen, Console, Hardware, Software,
and the rest of the ordinary application continue to work at their declared
levels. Mirror reports the missing planes and degrades rather than pretending
that empty observation is a valid result.

Install it only with a recovery path. See
[Install the NOW Extension](../how-to/install-extension.md).
