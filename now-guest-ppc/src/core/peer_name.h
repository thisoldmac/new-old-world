#ifndef NOW_PEER_NAME_H
#define NOW_PEER_NAME_H

/* The naming vocabulary this application uses for the two machines in
   the room, in one place - the guest-side counterpart to the host's
   `MachineNaming.swift`. Before this file the guest had ~30 hand-written
   "this Mac" / "the other Mac" sites across a dozen files, each free to
   drift from the others (one page already said "That Mac"). The scheme
   is egocentric, not the host's fixed "Guest"/"This Mac" vocabulary: THIS
   machine is always "This Mac" from its own point of view, and the
   connected one is named by what its own `hello` said about itself -
   the same field the host has sent since before this file existed
   (`HostAppState.swift` :: `Host.current().localizedName`, carried in
   `Hello.name`; see wire.c :: on_hello). No contract change was needed
   for G-8 - only a place to keep the answer once it arrives. */

/* Always "This Mac". A function rather than a literal because every
   call site should read as "ask the naming seam", not as one more place
   that happens to spell the words correctly today. */
void now_self_name(char *out, long cap);

/* The connected machine's name: `raw_peer_name` when it is non-empty,
   "Other Mac" otherwise - disconnected, or a peer whose `hello` carried
   no `name` at all. `raw_peer_name` may be NULL or "".

   PURE and Toolbox-free on purpose, matching wire_sleep.c's shape: the
   fallback rule is cheap and worth a test, and a test needs a fact to
   hand it rather than a live connection to fake. wire.c owns the actual
   fact (`g.peer_name`, per-connection state, cleared on disconnect -
   never prefs, because it describes a link, not a preference) and hands
   it here through `conn_peer_label()`, which every other file should
   call rather than reading `wire.c` state directly. */
void now_peer_name(const char *raw_peer_name, char *out, long cap);

#endif
