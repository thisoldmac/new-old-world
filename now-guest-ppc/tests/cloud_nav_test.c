/* The drive browser's Back/Forward history:
     cc -Wall -Wextra -Werror -I ../src -I ../src/cloud \
        cloud_nav_test.c ../src/cloud/cloud_nav.c -o /tmp/t && /tmp/t
   Exercised the way cloud_drive_view.c drives it: the test keeps a
   `current` path of its own and asks the history to move it, so every
   expectation is about where a person LANDS — browser-history
   semantics — never about the stacks' internal shape. */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "cloud_nav.h"

static CloudNav nav;
static char current[kCloudNavPathCap];

/* What cloud_drive_view.c does on a descend/Up/jump: record the path
   being left, then go. */
static void navigate(const char *to)
{
    cloud_nav_visit(&nav, current);
    snprintf(current, sizeof current, "%s", to);
}

static int go_back(void)
{
    char out[kCloudNavPathCap];

    if (!cloud_nav_back(&nav, current, out, sizeof out)) {
        return 0;
    }
    memcpy(current, out, sizeof current);
    return 1;
}

static int go_forward(void)
{
    char out[kCloudNavPathCap];

    if (!cloud_nav_forward(&nav, current, out, sizeof out)) {
        return 0;
    }
    memcpy(current, out, sizeof current);
    return 1;
}

static void start_at_root(void)
{
    cloud_nav_reset(&nav);
    current[0] = '\0';
}

int main(void)
{
    char untouched[kCloudNavPathCap];
    int i;

    /* A fresh history goes nowhere, and a refused move leaves both the
       out buffer and the current place alone. */
    start_at_root();
    assert(!cloud_nav_can_back(&nav));
    assert(!cloud_nav_can_forward(&nav));
    strcpy(untouched, "sentinel");
    assert(cloud_nav_back(&nav, current, untouched,
                          sizeof untouched) == 0);
    assert(cloud_nav_forward(&nav, current, untouched,
                             sizeof untouched) == 0);
    assert(strcmp(untouched, "sentinel") == 0);

    /* Root -> Attic -> Attic:Old Sites, then retrace and replay. */
    start_at_root();
    navigate("Attic");
    navigate("Attic:Old Sites");
    assert(cloud_nav_can_back(&nav));
    assert(!cloud_nav_can_forward(&nav));

    assert(go_back());
    assert(strcmp(current, "Attic") == 0);
    assert(cloud_nav_can_forward(&nav));

    assert(go_back());
    assert(strcmp(current, "") == 0);
    assert(!cloud_nav_can_back(&nav));
    assert(!go_back());

    assert(go_forward());
    assert(strcmp(current, "Attic") == 0);
    assert(go_forward());
    assert(strcmp(current, "Attic:Old Sites") == 0);
    assert(!cloud_nav_can_forward(&nav));
    assert(!go_forward());

    /* Back twice then navigating somewhere new forfeits Forward — the
       branch not taken is gone, as in every browser. */
    start_at_root();
    navigate("A");
    navigate("B");
    assert(go_back());               /* at A */
    navigate("C");
    assert(!cloud_nav_can_forward(&nav));
    assert(go_back());
    assert(strcmp(current, "A") == 0);

    /* Up is a plain navigation too: root -> A -> A:B, Up back to A,
       then Back must return to A:B (where Up was pressed), not skip
       it. */
    start_at_root();
    navigate("A");
    navigate("A:B");
    navigate("A");                   /* Up */
    assert(go_back());
    assert(strcmp(current, "A:B") == 0);

    /* The bound: 20 steps deep, only the last 16 retrace, and the
       walk lands exactly where each step was taken from — the oldest
       four are dropped, nothing is reordered. */
    start_at_root();
    for (i = 1; i <= 20; ++i) {
        char name[16];

        snprintf(name, sizeof name, "p%d", i);
        navigate(name);
    }
    for (i = 19; i >= 4; --i) {
        char name[16];

        snprintf(name, sizeof name, "p%d", i);
        assert(go_back());
        assert(strcmp(current, name) == 0);
    }
    assert(!cloud_nav_can_back(&nav));
    assert(!go_back());
    /* And the whole retrace replays forward, ending where we started. */
    for (i = 5; i <= 20; ++i) {
        assert(go_forward());
    }
    assert(strcmp(current, "p20") == 0);
    assert(!cloud_nav_can_forward(&nav));

    /* An over-long path is stored truncated but nul-terminated: Back
       still answers, and what it answers fits the caller's buffer. */
    start_at_root();
    {
        char long_path[400];
        char out[kCloudNavPathCap];

        memset(long_path, 'x', sizeof long_path - 1);
        long_path[sizeof long_path - 1] = '\0';
        cloud_nav_visit(&nav, long_path);
        assert(cloud_nav_back(&nav, "", out, sizeof out) == 1);
        assert(strlen(out) == kCloudNavPathCap - 1);
    }

    printf("cloud_nav_test: all assertions passed\n");
    return 0;
}
