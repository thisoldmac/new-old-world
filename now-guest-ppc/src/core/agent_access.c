#include "agent_access.h"

#include "mcp_layout.h"
#include "prefs.h"
#include "wire.h"

/* This machine's answer, said out loud rather than left to silence.

   The contract reads an ABSENT `hello.agent` as "this sender predates the
   field", never as consent. A machine that means to refuse has to say
   `disabled`, so a machine that means to allow has to say so too, or the
   two are told apart only by which one shipped first.

   The switch this file was holding a seam open for is now the MCP page,
   and it lands here as the file said it would: the answer is read from the
   preferences file, and nothing else in the guest and nothing on the wire
   changed shape. The default is still full access — today's behaviour on
   every deployed machine, and a prefs file written before the field
   existed carries no opinion, so it keeps it.

   The token spelling lives in mcp_layout.c rather than here, because that
   file is the one the native test compiles: a page that showed one word
   while the wire carried another is exactly the drift a single spelling
   prevents. Deliberately still a function and not a `#define` — a constant
   would inline into send_hello and close the seam. */

/* Read once, then held: `hello` asks for this at connect time and the page
   asks for it on every repaint, and neither wants a File Manager call.
   -1 until the first read, which is the only state that means "not yet
   asked". */
static int g_tier = -1;

AgentAccessTier now_agent_access_tier(void)
{
    if (g_tier < 0) {
        NowPrefs prefs;

        now_prefs_load(&prefs);
        g_tier = mcp_tier_from_short(prefs.agent_access);
        if (g_tier < 0) {
            g_tier = (int)kAgentAccessFull;
        }
    }
    return (AgentAccessTier)g_tier;
}

void now_agent_access_set_tier(AgentAccessTier tier)
{
    NowPrefs prefs;

    if (mcp_tier_from_short((short)tier) < 0) {
        return;
    }
    g_tier = (int)tier;
    now_prefs_load(&prefs);
    prefs.agent_access = (short)tier;
    (void)now_prefs_save(&prefs);
    /* Stored first, then said. hello carries this once per connection, so
       without the announcement a tier changed mid-session reached the host
       only when the link was rebuilt — and until then the host went on
       permitting what the person had just withdrawn. The announcement
       lives HERE rather than in the page because this is the one place the
       tier changes: a second setter (an installer, a console verb) gets
       the announcement by using this function, which is the property the
       one-seam rule was for. */
    now_wire_announce_agent_access();
}

const char *now_agent_access(void)
{
    return mcp_tier_token(now_agent_access_tier());
}
