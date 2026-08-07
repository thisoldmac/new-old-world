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
    check(strcmp(now_mirror_plane_name(kMirrorPlaneTransitions),
                 "Transitions") == 0,
          "P5 is named Transitions");

    /* **The whole enumeration, walked — not four planes named by hand.**
       Naming them one at a time is how P5 came to be missing: the page
       drew five rows against a four-row table and read one element past
       its end, which rendered as a blank line and read as a plane with
       nothing to say. A test that lists the planes it knows about cannot
       catch the plane nobody added, so this one asks the enumeration. */
    {
        int i;
        for (i = 0; i < kMirrorPlaneCount; ++i) {
            const char *name = now_mirror_plane_name((MirrorPlane)i);
            const char *purpose = now_mirror_plane_purpose((MirrorPlane)i);
            check(name != NULL && name[0] != '\0',
                  "every plane has a name");
            check(purpose != NULL && purpose[0] != '\0',
                  "every plane has a purpose");
        }
    }

    /* And a plane index that is not one: the page is fed by a resident
       over a shared table, so an out-of-range value is an input rather
       than an impossibility. The empty string is the answer; a read past
       the table is not. */
    check(now_mirror_plane_name((MirrorPlane)kMirrorPlaneCount)[0] == '\0',
          "a plane index past the end reads as empty, not as memory");

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
