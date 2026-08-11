/* The unified NOW Extension lifecycle reply, tested without a Macintosh. */

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

static void healthy(MirrorFacts *facts)
{
    int i;

    memset(facts, 0, sizeof *facts);
    facts->lifecycle = kMirrorLifecycleActive;
    facts->resident_major = 1;
    facts->resident_minor = 7;
    facts->table_length = 4096;
    facts->capabilities = 15;
    facts->requested_bits = 15;
    facts->active_bits = 15;
    facts->heartbeat = 1234;
    facts->has_build_identity = 1;
    for (i = 0; i < 5; ++i) {
        facts->source_manifest[i] = (unsigned long)(i + 1);
        facts->build_fingerprint[i] = (unsigned long)(0x10 + i);
    }
    for (i = 0; i < kMirrorPlaneCount; ++i) {
        MirrorPlaneFact *plane = &facts->planes[i];
        plane->supported = 1;
        plane->format = (unsigned long)(i + 1);
        plane->requested = 1;
        plane->active = 1;
        plane->freshness = kMirrorFreshCurrent;
        plane->state = kMirrorPlaneActiveCurrent;
        plane->generation = (unsigned long)(100 + i);
    }
}

int main(void)
{
    char buf[4096];
    MirrorFacts facts;
    long n;

    printf("mirror_json_test\n");
    healthy(&facts);
    n = now_mirror_json(&facts, 42, buf, (long)sizeof buf);
    check(n > 0, "active facts render");
    check(strstr(buf, "\"schema\":1") != NULL,
          "the mirror object carries its explicit schema");
    check(strstr(buf, "\"selector\":\"NWex\"") != NULL,
          "the one resident component is NOW Extension");
    check(strstr(buf, "\"lifecycle\":\"active\"") != NULL,
          "active is spelled as a lifecycle word");
    check(strstr(buf, "\"sourceManifest\":\"0000000100000002000000030000000400000005\"") != NULL,
          "source identity is exact lowercase SHA-1 hex");
    check(strstr(buf, "\"buildFingerprint\":\"0000001000000011000000120000001300000014\"") != NULL,
          "resident build identity travels beside source identity");
    check(strstr(buf, "\"policy\":{\"structure\":false,"
                      "\"finderComplements\":false,\"content\":false,"
                      "\"foregroundCycle\":false}") != NULL,
          "guest policy is a typed domain object, not inferred from planes");
    check(strstr(buf, "\"id\":\"structure\"") != NULL,
          "P1 structure is present");
    check(strstr(buf, "\"id\":\"semantics\"") != NULL,
          "P2 semantics is present");
    check(strstr(buf, "\"id\":\"content\"") != NULL,
          "P3 content is present");
    check(strstr(buf, "\"id\":\"interaction\"") != NULL,
          "P4 interaction is present");
    check(strstr(buf, "\"state\":\"active-current\"") != NULL,
          "current active planes are explicit");
    check(strstr(buf, "AXPeek") == NULL && strstr(buf, "QDPeek") == NULL
              && strstr(buf, "Portal") == NULL
              && strstr(buf, "mirror-agent") == NULL,
          "the retired three-extension and agent inventory cannot leak");

    memset(&facts, 0, sizeof facts);
    facts.lifecycle = kMirrorLifecycleNeedsRestart;
    now_mirror_json(&facts, 7, buf, (long)sizeof buf);
    check(strstr(buf, "\"lifecycle\":\"needs-restart\"") != NULL,
          "installed but unloaded is distinct from absent");
    check(strstr(buf, "\"residentMajor\":") == NULL,
          "an unloaded extension invents no resident version");

    memset(&facts, 0, sizeof facts);
    facts.lifecycle = kMirrorLifecycleWrongVersion;
    facts.resident_major = 9;
    facts.resident_minor = 2;
    now_mirror_json(&facts, 8, buf, (long)sizeof buf);
    check(strstr(buf, "\"lifecycle\":\"wrong-version\"") != NULL,
          "wrong-version is not absence");
    check(strstr(buf, "\"residentMajor\":9") != NULL,
          "wrong-version reports what answered");

    healthy(&facts);
    facts.lifecycle = kMirrorLifecycleDegraded;
    facts.planes[kMirrorPlaneContent].state = kMirrorPlaneDegraded;
    facts.planes[kMirrorPlaneContent].freshness = kMirrorFreshStale;
    strcpy(facts.planes[kMirrorPlaneContent].reason,
           "resident heartbeat is stale");
    now_mirror_json(&facts, 9, buf, (long)sizeof buf);
    check(strstr(buf, "\"lifecycle\":\"degraded\"") != NULL,
          "degraded lifecycle is explicit");
    check(strstr(buf, "\"freshness\":\"stale\"") != NULL,
          "plane freshness is explicit");
    check(strstr(buf, "resident heartbeat is stale") != NULL,
          "plane degradation carries its proving reason");

    healthy(&facts);
    facts.policy.structure = 1;
    facts.policy.finder_complements = 0;
    facts.policy.content = 1;
    facts.policy.foreground_cycle = 0;
    now_mirror_json(&facts, 11, buf, (long)sizeof buf);
    check(strstr(buf, "\"policy\":{\"structure\":true,"
                      "\"finderComplements\":false,\"content\":true,"
                      "\"foregroundCycle\":false}") != NULL,
          "each policy domain travels independently");

    healthy(&facts);
    {
        char small[64];
        long used = now_mirror_json(&facts, 10, small, (long)sizeof small);
        check(used < (long)sizeof small, "bounded output truncates safely");
    }

    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("  ok\n");
    return 0;
}
