#ifndef NOW_ACT_CMDS_H
#define NOW_ACT_CMDS_H

#include <Carbon.h>

/* The act plane's six commands, as the wire sees them.

   Three are declared in contract/asyncapi.yaml already - winact,
   textget, textset - and the host publishes a row for each. The other
   three complete the plane on this side:

     ctlact     drive one control, by answering the application's own
                TrackControl.
     ditemact   select one live Dialog Manager item through the owning
                application's dialog event path.
     menuact    perform one menu command, by answering the application's
                own MenuSelect.

   THE SEVENTH WENT NEXT DOOR. `elements` - the observation that MINTS the
   references the other six take - is now_observe_elements_command, in
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
void now_act_run_ditemact(const char *request_json, long id,
                          char *out, long cap);
void now_act_run_menuact(const char *request_json, long id,
                         char *out, long cap);

/* The application installs its bounded menu queue here. A menu act aimed at
   this process is accepted during the wire callback, then the application
   drains it from its next main event-loop turn. The return value says whether
   the one-slot queue accepted the choice. */
typedef int (*NowActSelfMenuHandler)(long choice);
void now_act_set_self_menu_handler(NowActSelfMenuHandler handler);

/* Window Manager hiding is not application close semantics. The owning
   application installs a bounded close dispatcher so its save/dispose/dialog
   path runs from the main event loop, just like a real close-box click. */
typedef int (*NowActSelfWindowCloseHandler)(WindowRef window);
void now_act_set_self_window_close_handler(
    NowActSelfWindowCloseHandler handler);

#endif /* NOW_ACT_CMDS_H */
