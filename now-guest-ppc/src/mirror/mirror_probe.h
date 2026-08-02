#ifndef NOW_MIRROR_PROBE_H
#define NOW_MIRROR_PROBE_H

#include "mirror_facts.h"

/* The Macintosh half of the Mirror page: Gestalt for the three residents,
   the Process Manager for the agent, LaunchApplication to start it and a
   'quit' Apple Event to stop it. Everything it learns lands in a
   MirrorFacts; what those facts MEAN lives in mirror_layout.c, where a
   host test can reach it.

   NOTHING HERE IS MIRROR'S CODE. The selectors and the block layouts are
   read from Mirror's own shared headers and named again locally, each
   with the file it came from. Copying those headers in would be a second
   copy of a contract, which is the failure mode this project has paid
   for on the wire and has no wish to repeat in memory. */

/* Everything, including where Mirror stages the agent and which port the
   `mirror.port` file beside it names. Does file I/O - FindFolder, a
   catalog walk and one short read - so it must NOT be called from an idle
   handler; the page calls it on creation and after an action. `facts` is
   fully written except for `note`, which the caller owns. */
void now_mirror_probe(MirrorFacts *facts);

/* Only the agent's state, from the location the last probe resolved. No
   file I/O: one bounded Process Manager walk, which is what an idle
   handler may afford about once a second. Leaves `note` alone - and
   leaves the port fields alone, because re-reading mirror.port every
   second would be a file opened on the idle path, which is the rule
   docs/guest-ui-start-here.md states about starving a transfer. A port
   file staged while this page is open is therefore stale here until the
   next action; every action re-probes. */
void now_mirror_poll_agent(MirrorFacts *facts);

/* Start the agent, and say in `facts->note` what happened either way. A
   launch that failed must arrive as words on the page; nothing else in
   this application will report it.

   It also REFUSES: when nothing beside the agent names the port it would
   serve, no process is started and the note says why. A launch this call
   knows will produce an unreachable agent is worse than no launch,
   because the page would then say "Running" about it. */
void now_mirror_agent_start(MirrorFacts *facts);

/* Ask the agent to quit - a 'quit' Apple Event to its own PSN, the same
   courtesy the Processes page extends and the same refusal to force it.
   The state does not change here: whether the agent honours the request
   is answered by the next poll, not by the send returning noErr. */
void now_mirror_agent_stop(MirrorFacts *facts);

#endif /* NOW_MIRROR_PROBE_H */
