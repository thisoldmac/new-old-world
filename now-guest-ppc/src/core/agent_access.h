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

/* Persists, and takes effect on the NEXT connection: `hello` is sent once
   at handshake and the contract carries no message that revises it, so a
   tier changed mid-session is this Mac's answer to the next host, not to
   the one already on the wire. The page says that rather than implying
   otherwise. */
void now_agent_access_set_tier(AgentAccessTier tier);

#endif /* NOW_AGENT_ACCESS_H */
