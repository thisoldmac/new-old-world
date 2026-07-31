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

#endif /* NOW_AGENT_ACCESS_H */
