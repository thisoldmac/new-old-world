#include "files_peer_label.h"

#include <stdio.h>
#include <string.h>

#if TARGET_API_MAC_CARBON
#include "wire.h"
#endif

static const char k_unknown[] = "Other Mac";

void now_files_peer_label(const char *reported, char *out, long cap)
{
    long i = 0;

    if (out == NULL || cap <= 0) {
        return;
    }
    if (reported != NULL) {
        /* A name of nothing but spaces is not a name. Whatever a machine
           sent, a heading has to read as one. */
        while (reported[i] == ' ' || reported[i] == '\t') {
            ++i;
        }
    }
    if (reported == NULL || reported[i] == '\0') {
        snprintf(out, (size_t)cap, "%s", k_unknown);
        return;
    }
    snprintf(out, (size_t)cap, "%s", reported + i);
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

    /* The snapshot's own peer_name, not conn_peer_label(): that one
       degrades to the sentence fragment "the other Mac" for use mid
       sentence, and a heading wants a name. One place converts. */
    conn_snapshot(&snap);
    now_files_peer_label(snap.peer_name, out, cap);
}
#endif
