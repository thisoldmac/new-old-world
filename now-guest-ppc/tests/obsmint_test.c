/* Native test for the minting seam the SCENE walk uses (src/observe/
   obsmint.c).
 *
 *     cc -Wall -Wextra -Werror -I ../src/observe -I ../src/axwalk \
 *        -I ../src/peek -I . obsmint_test.c ../src/observe/obsmint.c \
 *        ../src/observe/obsref.c ../src/observe/obsresolve.c \
 *        ../src/axwalk/axresolve.c ../src/axwalk/axwalk.c \
 *        ../src/peek/peek_validate.c -o obsmint_test && ./obsmint_test
 *
 * THE ONE CLAIM WORTH TESTING is not "a token comes back". It is that
 * the token comes back and then RESOLVES - through the same resolver the
 * act plane calls, against the same arena, to the same element. A scene
 * whose `ref` is a well-formed string that resolves to nothing is
 * decoration, and decoration is exactly what this whole change is
 * against: it would render a clickable-looking button whose every act is
 * refused, which is the state the scene was already in.
 *
 * So every assertion below is an end-to-end one: mint from an address,
 * then resolve the string and check WHICH element came back. The
 * duplicate-title case carries the most weight - two buttons labelled
 * "OK" in the same window resolve by occurrence, so a producer that
 * counted occurrences differently from the resolver would mint a
 * reference that lands on the neighbour. That failure has no symptom on
 * either side; it is one button acting for another.
 *
 * The refusals matter as much. An element a resolution could never reach
 * (past its bound, off the chain, on a chain that loops) must get NO
 * reference, because the producer's absent key means "not minted" and
 * that is the only honest thing to say.
 */

#include <stdio.h>
#include <string.h>

#include "axfixture.h"
#include "obsmint.h"
#include "obsresolve.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

enum {
    kRgnH = 0x0010F000,
    kRgn = 0x00402000,
    kPsnHi = 0,
    kPsnLo = 0x12345,
    kProcFingerprint = 0x0ABCDEF0,
    kTicks = 7700
};

static unsigned long win_at(int i)
{
    return 0x00101000UL + (unsigned long)i * 0x400UL;
}

static unsigned long ctl_handle(int w, int c)
{
    return 0x00108000UL + (unsigned long)w * 0x400UL
        + (unsigned long)c * 0x10UL;
}

static unsigned long ctl_record(int w, int c)
{
    return 0x0010C000UL + (unsigned long)w * 0x800UL
        + (unsigned long)c * 0x200UL;
}

/* The same synthetic WindowRecord/ControlRecord layout axresolve_test
   builds: one arena, one set of offsets, so a disagreement between the
   minter and the resolver cannot hide behind two different fixtures. */
static void build_window(AxFixture *f, unsigned long win, const char *title,
                         unsigned long controls, unsigned long next)
{
    unsigned long title_h = win + 0x200;
    unsigned long title_p = win + 0x220;

    axfix_put16(f, win + 16, 0);
    axfix_put16(f, win + 18, 0);
    axfix_put16(f, win + 108, 8);
    axfix_put8(f, win + 110, 1);
    axfix_put32(f, win + 118, kRgnH);
    axfix_put32(f, win + 134, title_h);
    axfix_put32(f, win + 140, controls);
    axfix_put32(f, win + 144, next);
    axfix_put_handle(f, title_h, title_p);
    axfix_put_pstr(f, title_p, title);
    axfix_put_handle(f, kRgnH, kRgn);
    axfix_put_region(f, kRgn, 0, 0, 200, 300);
}

static void build_control(AxFixture *f, unsigned long handle,
                          unsigned long record, const char *title,
                          unsigned long next)
{
    axfix_put32(f, record + 0, next);
    axfix_put16(f, record + 8, 0);
    axfix_put16(f, record + 10, 0);
    axfix_put16(f, record + 12, 20);
    axfix_put16(f, record + 14, 80);
    axfix_put8(f, record + 16, 1);
    axfix_put8(f, record + 17, 0);
    axfix_put_pstr(f, record + 40, title);
    axfix_put_handle(f, handle, record);
}

/* Two windows; the second holds two buttons both called "OK" and one
   called "Cancel". */
static void build_desktop(AxFixture *f)
{
    build_window(f, win_at(0), "Finder", 0, win_at(1));
    build_window(f, win_at(1), "Save", ctl_handle(1, 0), 0);
    build_control(f, ctl_handle(1, 0), ctl_record(1, 0), "OK",
                  ctl_handle(1, 1));
    build_control(f, ctl_handle(1, 1), ctl_record(1, 1), "OK",
                  ctl_handle(1, 2));
    build_control(f, ctl_handle(1, 2), ctl_record(1, 2), "Cancel", 0);
}

static void live_for(NowObsLive *live, const NowAxMemory *memory)
{
    memset(live, 0, sizeof(*live));
    live->bind = kNowObsBindOk;
    live->process_fingerprint = kProcFingerprint;
    live->window_list = win_at(0);
    live->memory = memory;
}

static void aim(NowObsWalk *walk, const NowAxMemory *memory)
{
    now_obs_walk_aim(walk, memory, win_at(0), kPsnHi, kPsnLo,
                     kProcFingerprint, kTicks);
}

/* --- the claim ---------------------------------------------------------- */

static void a_minted_window_ref_resolves(void)
{
    AxFixture        f;
    NowAxMemory      memory;
    NowObsRegistry   registry;
    NowObsWalk       walk;
    NowObsLive       live;
    NowObsResolution resolution;
    char             token[kNowObsTokenMax];

    axfix_init(&f, &memory);
    build_desktop(&f);
    now_obs_registry_init(&registry, 0x1234UL, 0x5678UL);
    now_obs_walk_begin(&walk, &registry);
    aim(&walk, &memory);
    live_for(&live, &memory);

    check(now_obs_walk_window_ref(&walk, win_at(1), token,
                                  sizeof(token)) == 1,
          "the scene walk mints a reference for a window it is holding");
    now_obs_resolve(&registry, kNowObsKindWindow, token, strlen(token),
                    &live, &resolution);
    check(resolution.verdict == kNowObsOk,
          "and that reference resolves through the act plane's resolver");
    check(resolution.resolved.window_address == win_at(1),
          "to the window the walk was holding, not another one");
    now_obs_walk_end(&walk);
}

/* The case with no symptom: two buttons wearing the same label. If the
   producer counts occurrences differently from the resolver, the token
   is well formed, resolution says Ok, and the WRONG button is acted
   on. */
static void a_minted_control_ref_resolves_to_the_right_twin(void)
{
    AxFixture        f;
    NowAxMemory      memory;
    NowObsRegistry   registry;
    NowObsWalk       walk;
    NowObsLive       live;
    NowObsResolution resolution;
    char             first[kNowObsTokenMax];
    char             second[kNowObsTokenMax];
    char             cancel[kNowObsTokenMax];

    axfix_init(&f, &memory);
    build_desktop(&f);
    now_obs_registry_init(&registry, 0x99UL, 0xAAUL);
    now_obs_walk_begin(&walk, &registry);
    aim(&walk, &memory);
    live_for(&live, &memory);

    check(now_obs_walk_control_ref(&walk, win_at(1), ctl_handle(1, 0), first,
                                   sizeof(first)) == 1, "the first OK mints");
    check(now_obs_walk_control_ref(&walk, win_at(1), ctl_handle(1, 1), second,
                                   sizeof(second)) == 1,
          "and so does the second");
    check(strcmp(first, second) != 0,
          "two buttons with one label are two references");

    now_obs_resolve(&registry, kNowObsKindElement, first, strlen(first),
                    &live, &resolution);
    check(resolution.verdict == kNowObsOk, "the first resolves");
    check(resolution.resolved.control_handle == ctl_handle(1, 0),
          "to the FIRST OK");
    now_obs_resolve(&registry, kNowObsKindElement, second, strlen(second),
                    &live, &resolution);
    check(resolution.verdict == kNowObsOk, "the second resolves");
    check(resolution.resolved.control_handle == ctl_handle(1, 1),
          "to the SECOND OK - the occurrence arithmetic agrees with the "
          "resolver's");

    check(now_obs_walk_control_ref(&walk, win_at(1), ctl_handle(1, 2), cancel,
                                   sizeof(cancel)) == 1, "Cancel mints");
    now_obs_resolve(&registry, kNowObsKindElement, cancel, strlen(cancel),
                    &live, &resolution);
    check(resolution.verdict == kNowObsOk
          && resolution.resolved.control_handle == ctl_handle(1, 2),
          "and resolves to Cancel");
    now_obs_walk_end(&walk);
}

/* Fetch the scene twice: same references, and the ones the first fetch
   handed the host are still live. This is the property that makes a
   rendered scene actionable at all - the person clicks the scene they
   are looking at, which is the one from the previous fetch. */
static void a_second_fetch_carries_the_same_references(void)
{
    AxFixture      f;
    NowAxMemory    memory;
    NowObsRegistry registry;
    NowObsWalk     walk;
    char           first_pass[kNowObsTokenMax];
    char           second_pass[kNowObsTokenMax];

    axfix_init(&f, &memory);
    build_desktop(&f);
    now_obs_registry_init(&registry, 0x2BUL, 0x2CUL);

    now_obs_walk_begin(&walk, &registry);
    aim(&walk, &memory);
    check(now_obs_walk_control_ref(&walk, win_at(1), ctl_handle(1, 0),
                                   first_pass, sizeof(first_pass)) == 1,
          "the first fetch mints");
    now_obs_walk_end(&walk);

    now_obs_walk_begin(&walk, &registry);
    aim(&walk, &memory);
    check(now_obs_walk_control_ref(&walk, win_at(1), ctl_handle(1, 0),
                                   second_pass, sizeof(second_pass)) == 1,
          "the second fetch answers");
    now_obs_walk_end(&walk);

    check(strcmp(first_pass, second_pass) == 0,
          "with the same reference - a refresh does not rename the desktop");
    check(registry.minted == 1 && registry.reused == 1,
          "and the registry did not grow by a scene");
}

/* --- the refusals ------------------------------------------------------- */

/* An address that is not on this process's chain is not this process's
   element, whatever it reads like. */
static void an_address_off_the_chain_is_refused(void)
{
    AxFixture      f;
    NowAxMemory    memory;
    NowObsRegistry registry;
    NowObsWalk     walk;
    char           token[kNowObsTokenMax];

    axfix_init(&f, &memory);
    build_desktop(&f);
    /* A perfectly well-formed window record that nothing links to. */
    build_window(&f, win_at(9), "Stranger", 0, 0);
    now_obs_registry_init(&registry, 5UL, 6UL);
    now_obs_walk_begin(&walk, &registry);
    aim(&walk, &memory);

    check(now_obs_walk_window_ref(&walk, win_at(9), token,
                                  sizeof(token)) == 0,
          "a window off the chain gets no reference");
    check(token[0] == '\0', "and no half-written one either");
    check(now_obs_walk_window_ref(&walk, 0x00500000UL, token,
                                  sizeof(token)) == 0,
          "nor does an address outside the partition");
    check(now_obs_walk_control_ref(&walk, win_at(1), ctl_handle(1, 7), token,
                                   sizeof(token)) == 0,
          "nor a control handle that is not on the window's chain");
    check(registry.minted == 0, "and nothing was filed for any of them");
    now_obs_walk_end(&walk);
}

/* The bound is the resolver's, not the producer's. A window past
   kNowAxResolveMaxWindows cannot be resolved - resolution stops counting
   and answers NotFound - so minting for it would produce a string that
   is a promise the layer cannot keep. */
static void an_element_past_the_resolvers_bound_is_refused(void)
{
    AxFixture        f;
    NowAxMemory      memory;
    NowObsRegistry   registry;
    NowObsWalk       walk;
    NowObsLive       live;
    NowObsResolution resolution;
    char             token[kNowObsTokenMax];
    char             last_reachable[kNowObsTokenMax];
    int              i;
    int              deep = kNowAxResolveMaxWindows;

    axfix_init(&f, &memory);
    for (i = 0; i <= deep; i++) {
        char title[16];

        snprintf(title, sizeof title, "W%d", i);
        build_window(&f, win_at(i), title, 0,
                     (i < deep) ? win_at(i + 1) : 0);
    }
    now_obs_registry_init(&registry, 21UL, 22UL);
    now_obs_walk_begin(&walk, &registry);
    aim(&walk, &memory);
    live_for(&live, &memory);

    check(now_obs_walk_window_ref(&walk, win_at(deep - 1), last_reachable,
                                  sizeof(last_reachable)) == 1,
          "the last window inside the bound mints");
    now_obs_resolve(&registry, kNowObsKindWindow, last_reachable,
                    strlen(last_reachable), &live, &resolution);
    check(resolution.verdict == kNowObsOk, "and resolves");

    check(now_obs_walk_window_ref(&walk, win_at(deep), token,
                                  sizeof(token)) == 0,
          "the one past it gets NO reference, because none could be "
          "redeemed");
    now_obs_walk_end(&walk);
}

/* A chain that points back at itself is refused rather than walked
   forever - the same answer the resolver gives it. */
static void a_cyclic_chain_is_refused(void)
{
    AxFixture      f;
    NowAxMemory    memory;
    NowObsRegistry registry;
    NowObsWalk     walk;
    char           token[kNowObsTokenMax];

    axfix_init(&f, &memory);
    build_window(&f, win_at(0), "A", 0, win_at(1));
    build_window(&f, win_at(1), "B", 0, win_at(0));
    now_obs_registry_init(&registry, 31UL, 32UL);
    now_obs_walk_begin(&walk, &registry);
    aim(&walk, &memory);

    check(now_obs_walk_window_ref(&walk, win_at(2), token,
                                  sizeof(token)) == 0,
          "a search down a looping chain refuses rather than spins");
    now_obs_walk_end(&walk);
}

/* No registry is not an excuse to invent one. A producer built without
   the reference layer emits every `ref` absent. */
static void no_registry_means_no_reference(void)
{
    AxFixture   f;
    NowAxMemory memory;
    NowObsWalk  walk;
    char        token[kNowObsTokenMax];

    axfix_init(&f, &memory);
    build_desktop(&f);
    now_obs_walk_begin(&walk, NULL);
    aim(&walk, &memory);
    check(now_obs_walk_window_ref(&walk, win_at(1), token,
                                  sizeof(token)) == 0,
          "a walk with no registry mints nothing");
    check(walk.granted == 0 && walk.refused == 1,
          "and says so in its own counters");
    now_obs_walk_end(&walk);
}

int main(void)
{
    a_minted_window_ref_resolves();
    a_minted_control_ref_resolves_to_the_right_twin();
    a_second_fetch_carries_the_same_references();
    an_address_off_the_chain_is_refused();
    an_element_past_the_resolvers_bound_is_refused();
    a_cyclic_chain_is_refused();
    no_registry_means_no_reference();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("obsmint: all checks passed\n");
    return 0;
}
