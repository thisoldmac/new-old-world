#ifndef NOW_CONTINUITY_HOSTDRAG_INTAKE_H
#define NOW_CONTINUITY_HOSTDRAG_INTAKE_H

/* continuity.hostDragBegin, read off the wire.
   ------------------------------------------------------------------
   Its own file for continuity_offer_intake.c's reason: this is the JSON
   half of one message and nothing else, so a lane working on the offer
   table and a lane working on the crossing never meet in a merge.

   It answers nothing. A hostDragBegin is an instruction, and the only
   honest report on it is what the drag itself does — which the ordinary
   drag log already says, joined to the host's own account by dragSeq. */
void now_continuity_hostdrag_intake(const char *request);

#endif /* NOW_CONTINUITY_HOSTDRAG_INTAKE_H */
