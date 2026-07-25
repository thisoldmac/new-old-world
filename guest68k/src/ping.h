#ifndef NOW68K_PING_H
#define NOW68K_PING_H

#include <stddef.h>

/* Keepalive direction rule (contract/asyncapi.yaml, "Keepalive is
 * GUEST-driven"): the guest sends ping after 30s of wire silence; the
 * host answers pong and never initiates a ping of its own. Enforcing the
 * 30s-idle timer and the 2-unanswered-pings death declaration is a
 * connection-state concern outside this codec -- this file only builds
 * the ping payload and recognises a pong, on whatever schedule the
 * caller decides to use them.
 */

/* Builds a ping control payload into buf (NUL-terminated). id is echoed
 * back by the host's pong (Ping.id / Pong.id, both required integers).
 * Returns the length written excluding the NUL, or 0 if buf is NULL,
 * cap <= 0, or the payload does not fit. */
long now68k_ping_build(char *buf, long cap, long id);

/* Recognises an inbound pong within json[0, json_len): type == "pong"
 * and a well-formed integer id. json need not be NUL-terminated -- only
 * json_len bounds the scan (see json_scan.h). On success returns 1 and,
 * if id_out is non-NULL, stores the id. Returns 0 for any other message
 * (including a malformed pong). */
int now68k_pong_read(const char *json, size_t json_len, long *id_out);

#endif
