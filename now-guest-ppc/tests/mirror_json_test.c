/* The `mirror` verb's reply, as the wire sees it.
 *
 *     cd now-guest-ppc/tests
 *     cc -Wall -Wextra -Werror -I ../src -I ../src/core -I ../src/mirror \
 *        mirror_json_test.c ../src/mirror/mirror_json.c \
 *        ../src/mirror/mirror_layout.c ../src/core/json.c -o /tmp/t && /tmp/t
 *
 * The sibling of mirror_layout_test.c, asking the other half of the same
 * question: that file checks what a state MEANS to a person, this one
 * checks how it is SPELLED to a caller. Both matter and they fail
 * separately - a page can say the right sentence while the wire says
 * `"state": 2`.
 *
 * THE THREE THINGS THIS EXISTS TO CATCH, each of which is silent:
 *
 *   1. A state spelled as its NUMBER. Every reader would then need a copy
 *      of the enum, which is the second-copy-of-a-contract failure this
 *      project has already paid for on the wire.
 *   2. A version or a port rendered when there is none. Zero is a number
 *      a reader believes: "port 0" reads as a listener, and a version on
 *      an absent extension reads as a version. Both must be ABSENT keys.
 *   3. A short extensions array. Three rows always, including absent
 *      ones - otherwise "not installed" and "not asked" are one answer.
 *
 * What this canNOT check, because it has no Macintosh: that Gestalt
 * answers at all, that the agent's creator is what the Process Manager
 * reports, or that mirror.port was read from the folder the catalog walk
 * resolved. mirror_probe.c owns all three and none is testable here.
 */

#include <stdio.h>
#include <string.h>

#include "mirror_json.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("  FAIL %s\n", what);
        ++failures;
    }
}

/* A machine with everything Mirror needs; each test breaks one thing. */
static void healthy(MirrorFacts *facts)
{
    int i;

    memset(facts, 0, sizeof *facts);
    for (i = 0; i < kMirrorExtCount; ++i) {
        facts->ext_state[i] = kMirrorExtResident;
    }
    facts->ext_version[kMirrorExtAX] = 4;
    facts->ext_version[kMirrorExtQD] = 1;
    facts->ext_version[kMirrorExtPortal] = 4;
    facts->agent = kMirrorAgentRunning;
    strcpy(facts->agent_path, "Macintosh HD:TimBotTu:mirror-dev:mirror-agent");
    strcpy(facts->agent_sig, "????");
    facts->port_state = kMirrorPortNamed;
    facts->port = kMirrorAgentPort;
}

static long render(const MirrorFacts *facts, char *out, long cap)
{
    return now_mirror_json(facts, 42, out, cap);
}

int main(void)
{
    char buf[2048];
    MirrorFacts facts;
    long n;

    printf("mirror_json_test\n");

    /* The healthy machine: every fact present, every one a word. */
    healthy(&facts);
    n = render(&facts, buf, sizeof buf);
    check(n > 0, "a healthy machine renders something");
    check(strstr(buf, "\"type\":\"command.result\"") != NULL,
          "the reply is a command.result");
    check(strstr(buf, "\"id\":42") != NULL, "it answers the id it was given");
    check(strstr(buf, "\"ok\":true") != NULL, "a probe that ran is ok");
    check(strstr(buf, "\"state\":\"resident\"") != NULL,
          "a loaded extension is the WORD resident, never its number");
    check(strstr(buf, "\"selector\":\"TBax\"") != NULL,
          "each row names the Gestalt selector it was read from");
    check(strstr(buf, "\"selector\":\"TBqd\"") != NULL, "QDPeek's selector");
    check(strstr(buf, "\"selector\":\"TBpt\"") != NULL, "the Portal's selector");
    check(strstr(buf, "\"state\":\"running\"") != NULL, "the agent is running");
    check(strstr(buf, "\"state\":\"named\"") != NULL, "the port state is named");
    check(strstr(buf, "\"number\":1420") != NULL, "and the number is there");
    check(strstr(buf, "\"source\":") != NULL,
          "the number says where it came from - the running agent bound "
          "what the file said at ITS launch, not what this read says");

    /* Three rows, always. A machine with nothing installed must still
       answer three, or "not installed" and "not asked" become one fact. */
    memset(&facts, 0, sizeof facts);
    n = render(&facts, buf, sizeof buf);
    {
        const char *p = buf;
        int rows = 0;
        while ((p = strstr(p, "\"name\":")) != NULL) {
            ++rows;
            ++p;
        }
        check(rows == kMirrorExtCount,
              "a bare machine still renders every extension row");
    }
    check(strstr(buf, "\"state\":\"absent\"") != NULL,
          "an extension that published nothing is absent");
    check(strstr(buf, "\"version\":") == NULL,
          "an ABSENT extension renders no version - a version there would "
          "be an invented fact about a block nobody read");
    check(strstr(buf, "\"state\":\"unknown\"") != NULL,
          "a port nobody could look for is unknown, not absent");
    check(strstr(buf, "\"number\":") == NULL,
          "a port that is not named renders NO number - 0 is a number a "
          "reader believes, and it would name a listener that is not there");
    check(strstr(buf, "\"signature\":") == NULL,
          "no signature without a running process to read it from");

    /* Other-version is not absence, and it keeps its version: that is the
       whole reason the third state exists. */
    memset(&facts, 0, sizeof facts);
    facts.ext_state[kMirrorExtPortal] = kMirrorExtOtherVersion;
    facts.ext_version[kMirrorExtPortal] = 9;
    n = render(&facts, buf, sizeof buf);
    check(strstr(buf, "\"state\":\"other-version\"") != NULL,
          "a block this build does not know is other-version, not absent");
    check(strstr(buf, "\"version\":9") != NULL,
          "and it reports the version it found, which is what tells "
          "somebody not to reinstall a file that is already there");

    /* The states that are NOT the healthy ones, each spelled its own way. */
    memset(&facts, 0, sizeof facts);
    facts.agent = kMirrorAgentStopped;
    facts.port_state = kMirrorPortUnusable;
    n = render(&facts, buf, sizeof buf);
    check(strstr(buf, "\"state\":\"stopped\"") != NULL, "a stopped agent");
    check(strstr(buf, "\"state\":\"unusable\"") != NULL,
          "a file naming no usable port is unusable, which is not absent: "
          "the file IS there and that is why the agent answers nobody");
    check(strstr(buf, "\"number\":") == NULL,
          "an unusable port names no number either");

    /* A path with a character JSON must escape. The agent path comes off
       a catalog walk, so a volume with a quote in its name is a machine
       this could meet. */
    memset(&facts, 0, sizeof facts);
    facts.agent = kMirrorAgentStopped;
    strcpy(facts.agent_path, "Macintosh \"HD\":mirror-dev:mirror-agent");
    n = render(&facts, buf, sizeof buf);
    check(strstr(buf, "\\\"HD\\\"") != NULL,
          "a quote in the path is escaped, not shipped raw into the JSON");

    /* A buffer far too small must truncate rather than run past cap. The
       return is the bytes used and must never reach cap. */
    healthy(&facts);
    {
        char small[64];
        long used = now_mirror_json(&facts, 7, small, (long)sizeof small);
        check(used < (long)sizeof small,
              "a reply that does not fit stops inside the buffer");
        check(small[sizeof small - 1] == '\0'
              || used < (long)sizeof small - 1,
              "and does not write past the end of it");
    }

    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("  ok\n");
    return 0;
}
