/* The Workshop's read-only projection of unified NOW Extension facts. */

#include <stdio.h>
#include <string.h>

#include "mirror_layout.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("  FAIL %s\n", what);
        ++failures;
    }
}

static void test_layout(void)
{
    Rect body = { 38, 160, 455, 744 };
    MirrorLayout layout;
    int i;

    now_mirror_layout_compute(&body, &layout);
    check(layout.heading.top >= body.top, "heading starts inside body");
    check(layout.lifecycle_rows[3].bottom <= layout.plane_heading.top,
          "extension facts precede plane facts");
    for (i = 1; i < kMirrorPlaneCount; ++i) {
        check(layout.plane_rows[i - 1].bottom <= layout.plane_rows[i].top,
              "plane rows do not overlap");
    }
    check(layout.note[1].bottom <= body.bottom,
          "read-only policy note fits the Workshop");
}

static void test_lifecycle_words(void)
{
    MirrorFacts facts;
    char out[180];

    memset(&facts, 0, sizeof facts);
    facts.lifecycle = kMirrorLifecycleAbsent;
    now_mirror_lifecycle_text(&facts, out, sizeof out);
    check(strstr(out, "not installed") != NULL, "absent is explicit");
    facts.lifecycle = kMirrorLifecycleNeedsRestart;
    now_mirror_lifecycle_text(&facts, out, sizeof out);
    check(strstr(out, "Restart") != NULL, "needs-restart names restart");
    facts.lifecycle = kMirrorLifecycleWrongVersion;
    facts.resident_major = 9;
    now_mirror_lifecycle_text(&facts, out, sizeof out);
    check(strstr(out, "version 9") != NULL, "wrong-version names resident");
    facts.lifecycle = kMirrorLifecycleActive;
    now_mirror_lifecycle_text(&facts, out, sizeof out);
    check(strstr(out, "active") != NULL, "active is explicit");
    facts.lifecycle = kMirrorLifecycleDegraded;
    now_mirror_lifecycle_text(&facts, out, sizeof out);
    check(strstr(out, "degraded") != NULL, "degraded is not active");
}

static void test_plane_words(void)
{
    MirrorFacts facts;
    char out[180];

    memset(&facts, 0, sizeof facts);
    check(strcmp(now_mirror_plane_name(kMirrorPlaneStructure), "Structure") == 0,
          "P1 is named Structure");
    check(strcmp(now_mirror_plane_name(kMirrorPlaneSemantics), "Semantics") == 0,
          "P2 is named Semantics");
    check(strcmp(now_mirror_plane_name(kMirrorPlaneContent), "Content") == 0,
          "P3 is named Content");
    check(strcmp(now_mirror_plane_name(kMirrorPlaneInteraction), "Interaction") == 0,
          "P4 is named Interaction");

    facts.planes[kMirrorPlaneSemantics].state = kMirrorPlaneUnsupported;
    now_mirror_plane_value(&facts, kMirrorPlaneSemantics, out, sizeof out);
    check(strcmp(out, "Unsupported") == 0,
          "unsupported cannot read as disabled");
    facts.planes[kMirrorPlaneSemantics].state = kMirrorPlaneRequested;
    now_mirror_plane_value(&facts, kMirrorPlaneSemantics, out, sizeof out);
    check(strstr(out, "Requested") != NULL, "requested is pending, not active");
    facts.planes[kMirrorPlaneSemantics].state = kMirrorPlaneActiveStale;
    facts.planes[kMirrorPlaneSemantics].format = 1;
    now_mirror_plane_value(&facts, kMirrorPlaneSemantics, out, sizeof out);
    check(strstr(out, "stale") != NULL && strstr(out, "format 1") != NULL,
          "stale active state keeps its format");
    facts.planes[kMirrorPlaneSemantics].state = kMirrorPlaneRefused;
    strcpy(facts.planes[kMirrorPlaneSemantics].reason, "wrong table length");
    now_mirror_plane_value(&facts, kMirrorPlaneSemantics, out, sizeof out);
    check(strstr(out, "Refused") != NULL && strstr(out, "wrong table") != NULL,
          "refusal is visible with its reason");
}

int main(void)
{
    printf("mirror_layout_test\n");
    test_layout();
    test_lifecycle_words();
    test_plane_words();
    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("  ok\n");
    return 0;
}
