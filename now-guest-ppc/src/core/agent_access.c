#include "agent_access.h"

/* Full access, and said out loud rather than left to silence.

   That is today's behaviour stated honestly, not a new permission: every
   deployed machine is already drivable end to end, and the contract reads
   an ABSENT `hello.agent` as "this sender predates the field", never as
   consent. A machine that means to refuse has to say `disabled`, so a
   machine that means to allow has to say so too, or the two are told apart
   only by which one shipped first.

   There is no switch and no installer yet — both are later slices, and both
   land HERE. When they do this reads the preference (or the absent
   component) and answers "disabled" or a tier; nothing else in the guest,
   and nothing on the wire, changes shape. Deliberately not a `#define`: a
   constant would get inlined into send_hello and the seam this exists to
   hold open would close. */
const char *now_agent_access(void)
{
    return "full";
}
