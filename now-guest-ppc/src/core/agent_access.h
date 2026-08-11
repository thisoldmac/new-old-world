#ifndef NOW_AGENT_ACCESS_H
#define NOW_AGENT_ACCESS_H

/* This machine's answer to whether a companion agent may drive it, as the
   wire token `hello.agent` carries: "disabled", "read-only" or "full"
   (contract/asyncapi.yaml). The machine states its position; the host is
   what enforces it, so nothing in this guest branches on the result.

   ONE function, so that when the switch and the installer land there is a
   single place that decides — and not a literal spelled into send_hello
   that a second one would have to be kept equal to. */
const char *now_agent_access(void);

/* The same fact as the ordered tier the MCP page shows and sets. This is
   the switch the paragraph above was holding the seam open for: the answer
   now comes from the preferences file rather than a constant, and
   `now_agent_access` is the wire's view of THAT — not a second store that
   would have to be kept equal to it. */
typedef enum {
    kAgentAccessDisabled = 0,
    kAgentAccessReadOnly = 1,
    kAgentAccessFull = 2
} AgentAccessTier;

AgentAccessTier now_agent_access_tier(void);

/* Persists, and tells a host already on the line (`agent.access`), because
   `hello` states this once per connection and a tier changed after it
   would otherwise not reach the host until the link was rebuilt — leaving
   the host enforcing a permission this machine had already withdrawn.

   This is the ONE place the tier changes, which is why it is also the one
   place that announces: a future setter gets the announcement by calling
   here. The guest learns that it SAID this, never that the host acted on
   it — there is no acknowledgement — so the page is worded to claim only
   the first. */
void now_agent_access_set_tier(AgentAccessTier tier);

#endif /* NOW_AGENT_ACCESS_H */
