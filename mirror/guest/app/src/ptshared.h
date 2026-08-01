/*
 * ptshared.h (agent side) — one line, on purpose.
 *
 * This file used to be a byte-identical COPY of the extension's header. Two
 * copies of a shared-memory ABI is the same hazard the Portal has already been
 * bitten by: a field added on one side and not the other does not fail to
 * build, it fails to AGREE, and a struct-offset disagreement across a shared
 * block is silent corruption rather than an error.
 *
 * It went unnoticed until 2026-07-31, when adding the MenuSelect click guard
 * compiled the extension clean and broke the agent — which is the LUCKY
 * ordering. Had the new fields landed in the agent's copy only, both sides
 * would have built and then disagreed at runtime.
 *
 * So there is one contract now, and the INIT owns it: the INIT is the resident
 * half, the agent is merely the caller, and the resident half is what a stale
 * build would be talking to. The version check in `verb_menuinvoke` covers the
 * case this cannot — a freshly built agent against an INIT still in the System
 * Folder from an older install.
 */
#ifndef PORTAL_PTSHARED_AGENT_H
#define PORTAL_PTSHARED_AGENT_H

#include "../../extensions/portal/src/ptshared.h"

#endif /* PORTAL_PTSHARED_AGENT_H */
