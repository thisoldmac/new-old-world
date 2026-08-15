#!/usr/bin/env python3
"""Pin the resident's packet-admission-before-lease ordering.

A keepalive is published by the Open Transport notifier while the Carbon
application can be starved in a nested Toolbox loop. The next cooperative
service call must admit that coherent packet before comparing the lease clock;
otherwise it expires an already-renewed epoch. This test names that exact
mutation in the only artifact the host compiler can inspect.
"""

from pathlib import Path


source = (
    Path(__file__).resolve().parents[2]
    / "ext"
    / "src"
    / "now_ext_continuity.c"
).read_text()
service = source.split("void now_ext_continuity_service(void)", 1)[1]
service = service.split("void now_ext_continuity_tick(TMTaskPtr task)", 1)[0]

coherence = service.index("if (before != cell->packet_seq)")
admission = service.index("cell->last_arrival_ticks = arrival")
lease = service.index("exit_due = now_continuity_exit_due")

assert coherence < admission < lease, (
    "Continuity service must prove the packet coherent and admit its arrival "
    "before evaluating lease expiry"
)

