#ifndef NOW_DEVELOPMENT_STAGE_REPLY_H
#define NOW_DEVELOPMENT_STAGE_REPLY_H

/* A development-stage refusal that NAMES the candidate it concerns,
   when one is known. A refusal without the minted candidate ID leaves
   guest residue no caller can address with stage-status or
   stage-discard (open-issues, 2026-08-09: two attempts, inactive
   residue, no agent-visible recovery handle). */
void dev_stage_refusal_reply(char *out, long cap, long id,
                             const char *code, const char *reason,
                             const char *candidate_id);

#endif
