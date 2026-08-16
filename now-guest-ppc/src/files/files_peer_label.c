#include "files_peer_label.h"

#include <stdio.h>
#include <string.h>

#include "peer_name.h"

#if TARGET_API_MAC_CARBON
#include "wire.h"
#endif

void now_files_peer_label(const char *reported, char *out, long cap)
{
    /* One converter for the whole app: core/peer_name.c owns the
       trim-and-fallback rule ("Other Mac"). This wrapper survives only
       as the module's local name for it. */
    now_peer_name(reported, out, cap);
}

void now_files_their_heading(const char *peer, char *out, long cap)
{
    char label[64];

    if (out == NULL || cap <= 0) {
        return;
    }
    now_files_peer_label(peer, label, sizeof label);
    /* An ASCII hyphen, not an em dash: a UTF-8 dash in a C literal
       reaches DrawString as mojibake (docs/guest-ui-start-here.md). */
    snprintf(out, (size_t)cap, "Their Files - %.40s", label);
}

void now_files_share_caption(const char *peer, char *out, long cap)
{
    char label[64];

    if (out == NULL || cap <= 0) {
        return;
    }
    now_files_peer_label(peer, label, sizeof label);
    snprintf(out, (size_t)cap, "%.40s can browse everything in here.",
             label);
}

#if TARGET_API_MAC_CARBON
void files_peer_label(char *out, long cap)
{
    ConnSnapshot snap;

    /* The snapshot's raw peer_name, converted through the one shared
       rule in core/peer_name.c. */
    conn_snapshot(&snap);
    now_files_peer_label(snap.peer_name, out, cap);
}
#endif
