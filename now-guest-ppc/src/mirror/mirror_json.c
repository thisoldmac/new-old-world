/*
 * mirror_json.c - the Mirror page's facts as the wire sees them.
 *
 * Toolbox-free, so the host `cc` runs the same emitter the guest ships
 * (mirror_json_test.c). Everything that needs a Macintosh is in
 * mirror_probe.c; what a state MEANS is in mirror_layout.c; this file
 * only decides how a fact is spelled on the wire.
 *
 * WHY THIS VERB IS SERVED BY THE GUEST AND CANNOT BE SERVED BY THE HOST.
 * Residency is a Gestalt answer. An extension publishes it at boot and
 * nothing else can; a host reading the Extensions FOLDER over the file
 * plane learns that a FILE exists, which is a different fact and the
 * wrong one - it cannot tell an installed-but-not-loaded extension from
 * a resident one, and that distinction is the whole question somebody
 * asks this page. NOW's Mirror page in the host was folder-listing until
 * this verb existed.
 *
 * THE THREE ENUMS ARE SPELLED AS WORDS, NEVER AS THEIR NUMBERS. A row
 * that said `"state": 2` would make every reader carry a copy of this
 * file's enum, which is the second-copy-of-a-contract failure the wire
 * has already paid for once. The words are the contract's enum values
 * and they are the same words the console face draws.
 *
 * ABSENT RATHER THAN ZERO, twice, and both are load-bearing:
 *
 *   version   omitted for an absent extension. A version rendered for
 *             something that published nothing is an invented fact.
 *   number    omitted unless the port state is "named". A page that
 *             printed 0 here would be naming a listener that does not
 *             exist, and 0 is a number a reader will believe.
 */

#include "mirror_json.h"

#include "json.h"

#include <stdio.h>
#include <string.h>

/* The contract's enum values, in the contract's order. Indexed by the
   MirrorExtState / MirrorAgentState / MirrorPortState the layout half
   already computed - so a state this file does not know is a compile
   error there rather than a wrong word here. */
static const char *ext_state_word(MirrorExtState state)
{
    switch (state) {
    case kMirrorExtResident:     return "resident";
    case kMirrorExtOtherVersion: return "other-version";
    case kMirrorExtAbsent:       break;
    }
    return "absent";
}

static const char *agent_state_word(MirrorAgentState state)
{
    switch (state) {
    case kMirrorAgentRunning: return "running";
    case kMirrorAgentStopped: return "stopped";
    case kMirrorAgentNoFile:  break;
    }
    return "no-file";
}

static const char *port_state_word(MirrorPortState state)
{
    switch (state) {
    case kMirrorPortNamed:    return "named";
    case kMirrorPortUnusable: return "unusable";
    case kMirrorPortAbsent:   return "absent";
    case kMirrorPortUnknown:  break;
    }
    return "unknown";
}

/* The Gestalt selector each row was read from, as four characters. Read
   from Mirror's own headers and named again here with the file it came
   from, exactly as mirror_probe.c does - copying those headers in would
   be a second copy of a contract in memory.

     mirror/guest/extensions/axpeek/src/axshared.h   'TBax'
     mirror/guest/extensions/qdpeek/src/qdshared.h   'TBqd'
     mirror/guest/extensions/portal/src/ptshared.h   'TBpt' */
static const char *ext_selector(MirrorExt which)
{
    switch (which) {
    case kMirrorExtQD:     return "TBqd";
    case kMirrorExtPortal: return "TBpt";
    case kMirrorExtAX:     break;
    }
    return "TBax";
}

long now_mirror_json(const MirrorFacts *facts, long id, char *out, long cap)
{
    char esc[kMirrorPathMax * 2 + 8];
    long n;
    int i;

    if (facts == NULL || out == NULL || cap <= 0) {
        return 0;
    }
    n = snprintf(out, cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                 "\"output\":{\"mirror\":{\"extensions\":[", id);

    /* Always all three, including the absent ones: a shorter array would
       make "not installed" and "not asked" the same answer. */
    for (i = 0; i < (int)kMirrorExtCount && n < cap; ++i) {
        MirrorExtState state = facts->ext_state[i];

        now_json_escape(now_mirror_ext_name((MirrorExt)i), esc, sizeof esc);
        n += snprintf(out + n, cap - n,
                      "%s{\"name\":\"%s\",\"selector\":\"%s\",\"state\":\"%s\"",
                      i == 0 ? "" : ",", esc, ext_selector((MirrorExt)i),
                      ext_state_word(state));
        if (state != kMirrorExtAbsent && n < cap) {
            n += snprintf(out + n, cap - n, ",\"version\":%lu",
                          facts->ext_version[i]);
        }
        if (n < cap) {
            n += snprintf(out + n, cap - n, "}");
        }
    }

    if (n < cap) {
        now_json_escape(facts->agent_path, esc, sizeof esc);
        n += snprintf(out + n, cap - n,
                      "],\"agent\":{\"state\":\"%s\",\"path\":\"%s\"",
                      agent_state_word(facts->agent), esc);
    }
    /* The creator only when something is running: it is read off the
       PROCESS, and there is no process to read it from otherwise. Weak
       even then - Retro68 stamps '????' on everything it builds,
       including the lab's own workers - so it is reported and not
       trusted, which is why it is a row rather than an identity. */
    if (facts->agent == kMirrorAgentRunning && facts->agent_sig[0] != '\0'
        && n < cap) {
        now_json_escape(facts->agent_sig, esc, sizeof esc);
        n += snprintf(out + n, cap - n, ",\"signature\":\"%s\"", esc);
    }
    if (n < cap) {
        n += snprintf(out + n, cap - n, "},\"port\":{\"state\":\"%s\"",
                      port_state_word(facts->port_state));
    }
    if (facts->port_state == kMirrorPortNamed && n < cap) {
        /* The source travels with the number because the two CAN
           disagree: the running agent bound whatever the file said at
           ITS launch, and this read is now. Saying where the number came
           from is what makes that one case legible instead of invisible. */
        n += snprintf(out + n, cap - n,
                      ",\"number\":%ld,\"source\":\"mirror.port beside the "
                      "agent, read now\"", facts->port);
    }
    if (n < cap) {
        n += snprintf(out + n, cap - n, "}}}}");
    }
    return n < cap ? n : cap - 1;
}
