#ifndef NOW_FILES_PEER_LABEL_H
#define NOW_FILES_PEER_LABEL_H

/* What this page calls the machine at the other end.

   The scheme, decided for the whole guest: this machine is "This Mac",
   and the other one is THE HOST'S OWN HOSTNAME when it has told us one,
   falling back to "Other Mac" when it has not. Guest and host are words
   for the code; a person reading a heading gets a machine's name or a
   plain description, never protocol vocabulary.

   THIS IS A SEAM, deliberately one file wide. A sibling lane is building
   `now_peer_name()` in core/ as the guest's single naming helper - the
   move MachineNaming already made on the host side. Until it lands, this
   page asks the connection snapshot directly. When it lands, the only
   edit is inside files_peer_label(): every heading, caption and status
   line on this page already reads through here.

   The RULE is pure and lives below the seam, so the fallback is decided
   by a test under the host cc rather than by looking at a Macintosh with
   nothing connected to it. */

/* `reported` is whatever the connection says the peer calls itself,
   possibly empty. Writes the label a person should read. */
void now_files_peer_label(const char *reported, char *out, long cap);

/* A short possessive-free heading: "Their Files - Maxbook Pro". */
void now_files_their_heading(const char *peer, char *out, long cap);

/* The consequence of sharing, in the peer's name:
   "Maxbook Pro can browse everything in here." */
void now_files_share_caption(const char *peer, char *out, long cap);

#if TARGET_API_MAC_CARBON
/* The live label, from the connection. */
void files_peer_label(char *out, long cap);
#endif

#endif /* NOW_FILES_PEER_LABEL_H */
