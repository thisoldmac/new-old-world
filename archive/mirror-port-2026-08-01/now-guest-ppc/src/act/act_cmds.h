#ifndef NOW_ACT_CMDS_H
#define NOW_ACT_CMDS_H

/* The act plane's five commands, as the wire sees them.

   Three are declared in contract/asyncapi.yaml already - winact,
   textget, textset - and the host publishes a row for each. The other
   two complete the plane on this side:

     ctlact     drive one control, by answering the application's own
                TrackControl.
     menuact    perform one menu command, by answering the application's
                own MenuSelect.

   THE SIXTH WENT NEXT DOOR. `elements` - the observation that MINTS the
   references the other five take - is now_observe_elements_command, in
   src/observe/. It was minting the same token shape as the reference
   layer from a second table, and two systems producing one token shape
   is a reference whose provenance a caller cannot tell. There is one
   minter; this file only asks it to resolve.

   WHAT THE REPLIES CLAIM, and it is the same for all of them: an event
   was DISPATCHED into the application's own path. Never that the window
   moved or the text changed. Where a re-read is cheap the reply carries
   it as a separate, labelled observation - and a re-read that fails is
   an absent row, not an error, because the act already happened. */

/* Every handler writes the whole command.result envelope into `out`, the
   way every other command in this table does. */
void now_act_run_winact(const char *request_json, long id,
                        char *out, long cap);
void now_act_run_textget(const char *request_json, long id,
                         char *out, long cap);
void now_act_run_textset(const char *request_json, long id,
                         char *out, long cap);
void now_act_run_ctlact(const char *request_json, long id,
                        char *out, long cap);
void now_act_run_menuact(const char *request_json, long id,
                         char *out, long cap);
/* V2: one menu's per-item geometry, read from its own MDEF rather than
   assumed at a fixed row height. Served outright - no click, no wait for
   a trap to answer, so this returns as soon as the target process next
   pumps its event loop. */
void now_act_run_menugeom(const char *request_json, long id,
                          char *out, long cap);

#endif /* NOW_ACT_CMDS_H */
