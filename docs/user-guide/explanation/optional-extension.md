---
page_id: optional-extension-explanation
title: The optional NOW Extension
description: Why the PowerPC resident exists, what it may observe, and why NOW must remain useful without it.
doc_type: explanation
audience: user
lifecycle: experimental
authority: [docs/resident-components.md, contract/peek_table.h]
source_dependencies: [docs/resident-components.md, contract/peek_table.h, ext]
media_ids: []
last_verified: 2026-08-09
---

# The optional NOW Extension

Some classic Macintosh facts exist only while another application is drawing
or handling events. The optional resident can observe those moments and publish
bounded state through one versioned in-memory table. The normal application
reads the table later; the host still communicates with the application over
the ordinary wire.

That ownership boundary is strict: foreign-context execution stays in the
resident, foreign-memory reads stay in the application, and the shared layout
lives once in `contract/peek_table.h`. The resident does not become a second
network stack or a required service.

Without the extension, Files, Processes, Screen, Console, Hardware, Software,
and the rest of the ordinary application continue to work at their declared
levels. Mirror reports the missing planes and degrades rather than pretending
that empty observation is a valid result.

Install it only with a recovery path. See
[Install the NOW Extension](../how-to/install-extension.md).
