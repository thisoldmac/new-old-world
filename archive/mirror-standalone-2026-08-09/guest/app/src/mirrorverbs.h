/*
 * mirrorverbs.h - the agent's one entry point from the transport.
 *
 * The transport hands over whole request lines and takes back whole reply
 * lines; it never knows what a verb is, and the verb layer never touches an
 * endpoint. Same seam the lab's wire has always had.
 */
#ifndef MIRRORVERBS_H
#define MIRRORVERBS_H

#include <stddef.h>

/* Handle one newline-terminated JSON request line, writing one newline-
 * terminated JSON reply into `out`. Returns the reply length, or -1 if the
 * reply would not fit (the caller drops the connection rather than emit a
 * truncated envelope). Runs on the MAIN loop, so it may call the Toolbox.
 * Matches OTReqHandler by design. */
int mirror_verb_handle(const char *line, size_t len, char *out, size_t cap);

/* Trace hook, owned by main.c. Logging both sides of the wire is a design
 * requirement here, not a debugging afterthought: a verb that actuates the UI
 * and then fails to reply is indistinguishable from a wedge unless the guest
 * says what it reached. Safe to call from the main loop only. */
void mirror_log(const char *msg);

#endif /* MIRRORVERBS_H */
