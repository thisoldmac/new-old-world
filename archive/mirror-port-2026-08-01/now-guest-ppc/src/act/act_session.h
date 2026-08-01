#ifndef NOW_ACT_SESSION_H
#define NOW_ACT_SESSION_H

/* The act pump's lifecycle, from this application's side.
   ------------------------------------------------------------------

   The pump (now-pump/) is a separate faceless application, because a
   click has to be posted from a CLASSIC process's own context and this
   one is Carbon (contract/peek_table.h, P4b). Something has to start it
   and something has to stop it, and this file is both.

   THE SHAPE, and it is three mechanisms rather than one because no one
   of them survives every failure:

     LAUNCH   when a host session opens - a live connection is the only
              thing a click can ever be asked for, so a pump running at
              any other time is a process nobody needs.
     QUIT     when the session closes, by Apple Event, which is how a
              Macintosh asks an application to go.
     HEARTBEAT while it runs. The pump watches session_heartbeat and
              exits on its own when it goes stale. This is the one that
              covers the case the other two cannot: a host that dies or
              an application that takes a Type 11 sends no Apple Event,
              and would otherwise leave a faceless process running with
              no window to close and nothing on screen to say it is
              there. The beat is written every event-loop pass.

   WHAT IT DOES NOT DO. It never launches a second pump - now-pump's own
   main() also refuses to be the second - and it never treats a failure
   to launch as fatal. A machine with no pump installed still serves
   every read on the act plane and still publishes its clicks by V3's
   inline route, which is exactly the state docs/open-issues.md already
   describes under act-click-no-pass. The product degrades honestly without it, which is
   what makes it a resident-family component rather than a dependency
   (docs/resident-components.md). */

/* Every event-loop pass, idle included. Cheap when there is nothing to
   do: one read of the connection phase and one word written. */
void now_act_session_service(void);

/* Before the application quits. Closes the session explicitly rather
   than letting the beat go stale, so the pump exits at once instead of
   ten seconds later - and so a reader can tell a clean shutdown from a
   crash. */
void now_act_session_close(void);

#endif /* NOW_ACT_SESSION_H */
