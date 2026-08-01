/* Native test for reference resolution - every refusal, told apart.

       cc -Wall -Wextra -Werror -I ../src/observe -I ../src/axwalk \
          -I ../src/peek -I . obsresolve_test.c \
          ../src/observe/obsresolve.c ../src/observe/obsref.c \
          ../src/axwalk/axresolve.c ../src/axwalk/axwalk.c \
          ../src/peek/peek_validate.c -o obsresolve_test && ./obsresolve_test

   The cases worth having are the ones where a WRONG answer looks exactly
   like a right one: a window that closed and reopened at a new address
   under the same title, a process serial number a different application
   now owns, two anchor slots claiming one partition. On a real machine
   none of those can be produced on demand - you cannot ask an emulator to
   recycle a PSN at the moment of your choosing - which is why the
   resolver takes the machine's state as an argument and the whole of it
   is reachable here.

   It reuses axfixture.h, the synthetic big-endian heap the walk's own
   tests use, for exactly the reason that fixture exists: the structures
   being read are not host-order, and a test that wrote host-order words
   would pass against a parser that read them. */

#include <stdio.h>
#include <string.h>

#include "axfixture.h"
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
    kProcFp = 0x0ABCDEF0
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

/* The same offsets the walk's own tests build against; see axwalk.h on
   why those numbers are evidence rather than style. */
static void build_window(AxFixture *f, unsigned long win, const char *title,
                         int visible, unsigned long controls,
                         unsigned long next)
{
    unsigned long title_h = win + 0x200;
    unsigned long title_p = win + 0x220;

    axfix_put16(f, win + 16, 0);
    axfix_put16(f, win + 18, 0);
    axfix_put16(f, win + 108, 8);
    axfix_put8(f, win + 110, visible ? 1 : 0);
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

/* Two windows; the second holds two buttons both called "OK". */
static void build_scene(AxFixture *f)
{
    build_window(f, win_at(0), "Finder", 1, 0, win_at(1));
    build_window(f, win_at(1), "Save", 1, ctl_handle(1, 0), 0);
    build_control(f, ctl_handle(1, 0), ctl_record(1, 0), "OK",
                  ctl_handle(1, 1));
    build_control(f, ctl_handle(1, 1), ctl_record(1, 1), "OK",
                  ctl_handle(1, 2));
    build_control(f, ctl_handle(1, 2), ctl_record(1, 2), "Cancel", 0);
}

/* What an observation does: record what it saw, then mint. Split out
   because every case below mints the same way and then changes exactly
   one thing about the world. */
static void mint_element(NowObsRegistry *registry, char *token, size_t cap,
                         const char *win_title, unsigned int win_n,
                         const char *ctl_title, unsigned int ctl_n,
                         unsigned long window, unsigned long control)
{
    NowObsIdentity id;

    memset(&id, 0, sizeof(id));
    id.psn_hi = kPsnHi;
    id.psn_lo = kPsnLo;
    id.process_fingerprint = kProcFp;
    id.window_address = window;
    id.control_handle = control;
    id.node_fingerprint = now_ax_ref_fingerprint(kPsnHi, kPsnLo, window,
                                                 control);
    id.ref.psn_hi = kPsnHi;
    id.ref.psn_lo = kPsnLo;
    strcpy((char *)id.ref.window_title, win_title);
    id.ref.window_title_len = strlen(win_title);
    id.ref.window_occurrence = win_n;
    strcpy((char *)id.ref.control_title, ctl_title);
    id.ref.control_title_len = strlen(ctl_title);
    id.ref.control_occurrence = ctl_n;
    id.ref.node_fingerprint = id.node_fingerprint;
    check(now_obs_mint(registry, kNowObsKindElement, &id, token, cap) == 1,
          "mint an element reference");
}

static void mint_window(NowObsRegistry *registry, char *token, size_t cap,
                        const char *win_title, unsigned int win_n,
                        unsigned long window)
{
    NowObsIdentity id;

    memset(&id, 0, sizeof(id));
    id.psn_hi = kPsnHi;
    id.psn_lo = kPsnLo;
    id.process_fingerprint = kProcFp;
    id.window_address = window;
    id.control_handle = 0;
    id.node_fingerprint = now_ax_ref_fingerprint(kPsnHi, kPsnLo, window, 0UL);
    id.ref.psn_hi = kPsnHi;
    id.ref.psn_lo = kPsnLo;
    strcpy((char *)id.ref.window_title, win_title);
    id.ref.window_title_len = strlen(win_title);
    id.ref.window_occurrence = win_n;
    id.ref.node_fingerprint = id.node_fingerprint;
    check(now_obs_mint(registry, kNowObsKindWindow, &id, token, cap) == 1,
          "mint a window reference");
}

static void live_ok(NowObsLive *live, const NowAxMemory *memory)
{
    memset(live, 0, sizeof(*live));
    live->bind = kNowObsBindOk;
    live->process_fingerprint = kProcFp;
    live->window_list = win_at(0);
    live->memory = memory;
}

static void resolves(void)
{
    AxFixture        f;
    NowAxMemory      m;
    NowObsRegistry   registry;
    NowObsLive       live;
    NowObsResolution got;
    char             token[kNowObsTokenMax];

    axfix_init(&f, &m);
    build_scene(&f);
    now_obs_registry_init(&registry, 0x1234UL, 0x5678UL);
    live_ok(&live, &m);

    mint_element(&registry, token, sizeof(token), "Save", 0, "Cancel", 0,
                 win_at(1), ctl_handle(1, 2));
    now_obs_resolve(&registry, kNowObsKindElement, token, strlen(token),
                    &live, &got);
    check(got.verdict == kNowObsOk, "an unchanged element resolves");
    check(got.why == kNowObsWhyNone, "with no reason to refuse");
    check(got.resolved.window_address == win_at(1), "to the right window");
    check(got.resolved.control_handle == ctl_handle(1, 2),
          "and the right control");
    check(strcmp(got.resolved.control.title, "Cancel") == 0,
          "carrying the control's own live fields");

    /* The duplicate-title case, which is the reason occurrences are part
       of a reference at all: both buttons say OK, and the reference has
       to name one of them and only one. */
    mint_element(&registry, token, sizeof(token), "Save", 0, "OK", 1,
                 win_at(1), ctl_handle(1, 1));
    now_obs_resolve(&registry, kNowObsKindElement, token, strlen(token),
                    &live, &got);
    check(got.verdict == kNowObsOk
          && got.resolved.control_handle == ctl_handle(1, 1),
          "the second OK resolves to the second OK");
}

static void window_references_resolve(void)
{
    AxFixture        f;
    NowAxMemory      m;
    NowObsRegistry   registry;
    NowObsLive       live;
    NowObsResolution got;
    char             token[kNowObsTokenMax];

    axfix_init(&f, &m);
    build_scene(&f);
    now_obs_registry_init(&registry, 9UL, 9UL);
    live_ok(&live, &m);

    mint_window(&registry, token, sizeof(token), "Save", 0, win_at(1));
    now_obs_resolve(&registry, kNowObsKindWindow, token, strlen(token),
                    &live, &got);
    check(got.verdict == kNowObsOk, "a window reference resolves");
    check(got.resolved.window_address == win_at(1), "to its window");
    check(got.resolved.control_handle == 0,
          "and names no control, because it named none");
    check(got.resolved.window_z == 1, "z is its index in the chain");

    /* An element token is not a window token even though the strings
       differ only in a prefix. */
    now_obs_resolve(&registry, kNowObsKindElement, token, strlen(token),
                    &live, &got);
    check(got.verdict == kNowObsNotFound && got.why == kNowObsWhyMalformed,
          "a window reference offered as an element is refused by shape");
}

/* THE test. The window closed and reopened: same title, same
   occurrence, same process, same everything a person can see - at a new
   address. The title still resolves, which is precisely the danger. */
static void a_reopened_window_is_a_different_window(void)
{
    AxFixture        f;
    NowAxMemory      m;
    NowObsRegistry   registry;
    NowObsLive       live;
    NowObsResolution got;
    char             element[kNowObsTokenMax];
    char             window[kNowObsTokenMax];

    axfix_init(&f, &m);
    build_scene(&f);
    now_obs_registry_init(&registry, 3UL, 4UL);
    live_ok(&live, &m);

    mint_element(&registry, element, sizeof(element), "Save", 0, "Cancel", 0,
                 win_at(1), ctl_handle(1, 2));
    mint_window(&registry, window, sizeof(window), "Save", 0, win_at(1));

    /* Rebuild the same-looking scene with the Save window at win_at(2). */
    memset(&f, 0, sizeof(f));
    build_window(&f, win_at(0), "Finder", 1, 0, win_at(2));
    build_window(&f, win_at(2), "Save", 1, ctl_handle(2, 0), 0);
    build_control(&f, ctl_handle(2, 0), ctl_record(2, 0), "OK",
                  ctl_handle(2, 1));
    build_control(&f, ctl_handle(2, 1), ctl_record(2, 1), "OK",
                  ctl_handle(2, 2));
    build_control(&f, ctl_handle(2, 2), ctl_record(2, 2), "Cancel", 0);

    now_obs_resolve(&registry, kNowObsKindElement, element, strlen(element),
                    &live, &got);
    check(got.verdict == kNowObsStale,
          "the element is STALE, not silently re-aimed at the new window");
    check(got.why == kNowObsWhyAddressesMoved, "and says why");
    check(got.resolved.control_handle == 0,
          "a refusal fills nothing - there is no honest value to put there");

    now_obs_resolve(&registry, kNowObsKindWindow, window, strlen(window),
                    &live, &got);
    check(got.verdict == kNowObsStale,
          "and so is the window reference, by the same arithmetic");
    check(got.resolved.window_address == 0, "which also fills nothing");
}

/* THE TWO STALENESS GUARDS, PROVED SEPARATELY.

   There are two, and in the ordinary reopened-window case they both fire
   at once, so a test that only exercises that case passes with either
   one deleted - which is not coverage, it is two half-tested checks
   propping each other up. (Found by mutating each and watching the suite
   stay green.)

     1. THE FINGERPRINT, inside the walk. The reference's own hash of the
        addresses it was minted against. This is the guard a consumer
        calling now_ax_resolve_ref directly - the act plane, without this
        registry - is relying on, so it has to hold alone.
     2. THE RECORDED ADDRESSES, after the walk. The registry's own copy.
        This is the guard against the TABLE being wrong rather than the
        machine having moved.

   Each case below arranges for exactly one of them to disagree. */
static void the_two_staleness_guards_are_independent(void)
{
    AxFixture        f;
    NowAxMemory      m;
    NowObsRegistry   registry;
    NowObsLive       live;
    NowObsResolution got;
    NowObsIdentity   id;
    char             token[kNowObsTokenMax];

    axfix_init(&f, &m);
    build_scene(&f);
    now_obs_registry_init(&registry, 0x77UL, 0x88UL);
    live_ok(&live, &m);

    /* (1) The addresses the registry recorded are exactly where the walk
       lands - only the reference's own fingerprint was minted against a
       different pair. Nothing but the fingerprint can catch this. */
    memset(&id, 0, sizeof(id));
    id.psn_hi = kPsnHi;
    id.psn_lo = kPsnLo;
    id.process_fingerprint = kProcFp;
    id.window_address = win_at(1);
    id.control_handle = ctl_handle(1, 2);
    id.ref.psn_hi = kPsnHi;
    id.ref.psn_lo = kPsnLo;
    strcpy((char *)id.ref.window_title, "Save");
    id.ref.window_title_len = 4;
    strcpy((char *)id.ref.control_title, "Cancel");
    id.ref.control_title_len = 6;
    id.ref.node_fingerprint = now_ax_ref_fingerprint(kPsnHi, kPsnLo,
                                                     win_at(1),
                                                     ctl_handle(1, 0));
    id.node_fingerprint = id.ref.node_fingerprint;
    check(now_obs_mint(&registry, kNowObsKindElement, &id, token,
                       sizeof(token)) == 1, "mint");
    now_obs_resolve(&registry, kNowObsKindElement, token, strlen(token),
                    &live, &got);
    check(got.verdict == kNowObsStale && got.why == kNowObsWhyAddressesMoved,
          "the fingerprint alone refuses a reference minted against "
          "different addresses");

    /* The window-only walk carries its own copy of that test, so it gets
       its own case: same arrangement, no control. */
    memset(&id, 0, sizeof(id));
    id.psn_hi = kPsnHi;
    id.psn_lo = kPsnLo;
    id.process_fingerprint = kProcFp;
    id.window_address = win_at(1);
    id.ref.psn_hi = kPsnHi;
    id.ref.psn_lo = kPsnLo;
    strcpy((char *)id.ref.window_title, "Save");
    id.ref.window_title_len = 4;
    id.ref.node_fingerprint = now_ax_ref_fingerprint(kPsnHi, kPsnLo,
                                                     win_at(0), 0UL);
    id.node_fingerprint = id.ref.node_fingerprint;
    check(now_obs_mint(&registry, kNowObsKindWindow, &id, token,
                       sizeof(token)) == 1, "mint a window reference");
    now_obs_resolve(&registry, kNowObsKindWindow, token, strlen(token),
                    &live, &got);
    check(got.verdict == kNowObsStale && got.why == kNowObsWhyAddressesMoved,
          "and the window walk's own copy of it does the same");

    /* (2) The fingerprint agrees with where the walk lands, and the
       registry's recorded address does not. Only the second guard can
       catch this one. */
    memset(&id, 0, sizeof(id));
    id.psn_hi = kPsnHi;
    id.psn_lo = kPsnLo;
    id.process_fingerprint = kProcFp;
    id.window_address = win_at(0);          /* not where "Save" is */
    id.control_handle = ctl_handle(1, 2);
    id.ref.psn_hi = kPsnHi;
    id.ref.psn_lo = kPsnLo;
    strcpy((char *)id.ref.window_title, "Save");
    id.ref.window_title_len = 4;
    strcpy((char *)id.ref.control_title, "Cancel");
    id.ref.control_title_len = 6;
    id.ref.node_fingerprint = now_ax_ref_fingerprint(kPsnHi, kPsnLo,
                                                     win_at(1),
                                                     ctl_handle(1, 2));
    id.node_fingerprint = id.ref.node_fingerprint;
    check(now_obs_mint(&registry, kNowObsKindElement, &id, token,
                       sizeof(token)) == 1, "mint");
    now_obs_resolve(&registry, kNowObsKindElement, token, strlen(token),
                    &live, &got);
    check(got.verdict == kNowObsStale && got.why == kNowObsWhyAddressesMoved,
          "the recorded addresses alone refuse a walk that landed "
          "elsewhere");
}

static void every_refusal_is_told_apart(void)
{
    AxFixture        f;
    NowAxMemory      m;
    NowObsRegistry   registry;
    NowObsLive       live;
    NowObsResolution got;
    char             token[kNowObsTokenMax];

    axfix_init(&f, &m);
    build_scene(&f);
    now_obs_registry_init(&registry, 5UL, 6UL);
    mint_element(&registry, token, sizeof(token), "Save", 0, "Cancel", 0,
                 win_at(1), ctl_handle(1, 2));

    /* Malformed: never even looked up. */
    live_ok(&live, &m);
    now_obs_resolve(&registry, kNowObsKindElement, "now-element-nope", 16,
                    &live, &got);
    check(got.verdict == kNowObsNotFound && got.why == kNowObsWhyMalformed,
          "a malformed reference is malformed, not missing");

    /* Well-formed, never minted here. */
    now_obs_resolve(&registry, kNowObsKindElement,
                    "now-element-01234567-89ab-cdef-0123-456789abcdef", 48,
                    &live, &got);
    check(got.verdict == kNowObsNotFound && got.why == kNowObsWhyUnminted,
          "a well-formed reference nobody minted is unminted, not malformed");

    /* The anchor plane's own answers, each mapped to its own verdict. */
    live_ok(&live, &m);
    live.bind = kNowObsBindAmbiguous;
    now_obs_resolve(&registry, kNowObsKindElement, token, strlen(token),
                    &live, &got);
    check(got.verdict == kNowObsAmbiguous
          && got.why == kNowObsWhyOracleAmbiguous,
          "two slots claiming the partition is AMBIGUOUS - refused, not "
          "guessed");

    live.bind = kNowObsBindMismatch;
    now_obs_resolve(&registry, kNowObsKindElement, token, strlen(token),
                    &live, &got);
    check(got.verdict == kNowObsMismatch
          && got.why == kNowObsWhyOracleMismatch,
          "a slot describing another address space is MISMATCH");

    live.bind = kNowObsBindNoAnchor;
    now_obs_resolve(&registry, kNowObsKindElement, token, strlen(token),
                    &live, &got);
    check(got.verdict == kNowObsNotFound && got.why == kNowObsWhyNoAnchor,
          "an unpumped process is NotFound, and says which NotFound");

    live.bind = kNowObsBindNoPlane;
    now_obs_resolve(&registry, kNowObsKindElement, token, strlen(token),
                    &live, &got);
    check(got.why == kNowObsWhyNoPlane,
          "an absent extension is distinguishable from an unpumped process");

    live.bind = kNowObsBindNoProcess;
    now_obs_resolve(&registry, kNowObsKindElement, token, strlen(token),
                    &live, &got);
    check(got.why == kNowObsWhyNoProcess, "and from a dead process");

    /* The recycled PSN: live, bound, and a different program. The read
       count is the assertion that matters as much as the verdict - the
       walk is the dangerous half, and this must be decided BEFORE a
       single byte of a stranger's heap is touched. */
    live_ok(&live, &m);
    live.process_fingerprint = kProcFp + 1;
    f.reads = 0;
    now_obs_resolve(&registry, kNowObsKindElement, token, strlen(token),
                    &live, &got);
    check(got.verdict == kNowObsMismatch
          && got.why == kNowObsWhyProcessRecycled,
          "a recycled PSN is a MISMATCH, never a resolve against a "
          "stranger");
    check(f.reads == 0,
          "and nothing was read from its memory to find that out");

    /* The element genuinely gone. */
    live_ok(&live, &m);
    mint_element(&registry, token, sizeof(token), "Save", 0, "Print", 0,
                 win_at(1), ctl_handle(1, 2));
    now_obs_resolve(&registry, kNowObsKindElement, token, strlen(token),
                    &live, &got);
    check(got.verdict == kNowObsNotFound && got.why == kNowObsWhyElementGone,
          "a title that names nothing now is NotFound");

    /* No windows at all. */
    live_ok(&live, &m);
    live.window_list = 0;
    mint_element(&registry, token, sizeof(token), "Save", 0, "Cancel", 0,
                 win_at(1), ctl_handle(1, 2));
    now_obs_resolve(&registry, kNowObsKindElement, token, strlen(token),
                    &live, &got);
    check(got.why == kNowObsWhyNoWindowList,
          "a process with no windows says so");
}

static void a_cycle_is_refused(void)
{
    AxFixture        f;
    NowAxMemory      m;
    NowObsRegistry   registry;
    NowObsLive       live;
    NowObsResolution got;
    char             token[kNowObsTokenMax];

    axfix_init(&f, &m);
    build_window(&f, win_at(0), "Finder", 1, 0, win_at(1));
    build_window(&f, win_at(1), "Save", 1, 0, win_at(0));   /* loops back */
    now_obs_registry_init(&registry, 8UL, 8UL);
    live_ok(&live, &m);

    mint_window(&registry, token, sizeof(token), "Print", 0, win_at(1));
    now_obs_resolve(&registry, kNowObsKindWindow, token, strlen(token),
                    &live, &got);
    check(got.verdict == kNowObsNotFound && got.why == kNowObsWhyCycle,
          "a window chain that loops is refused as a cycle");
}

/* The bound is on the WALK, not on the answer: a chain longer than the
   cap is NotFound rather than "whatever I had seen by then". */
static void a_chain_longer_than_the_bound_is_refused(void)
{
    AxFixture        f;
    NowAxMemory      m;
    NowObsRegistry   registry;
    NowObsLive       live;
    NowObsResolution got;
    char             token[kNowObsTokenMax];
    int              i;
    int              last = kNowAxResolveMaxWindows + 1;

    axfix_init(&f, &m);
    for (i = 0; i <= last; i++) {
        build_window(&f, win_at(i), (i == last) ? "Save" : "Filler", 1, 0,
                     (i == last) ? 0UL : win_at(i + 1));
    }
    now_obs_registry_init(&registry, 2UL, 2UL);
    live_ok(&live, &m);

    mint_window(&registry, token, sizeof(token), "Save", 0, win_at(last));
    now_obs_resolve(&registry, kNowObsKindWindow, token, strlen(token),
                    &live, &got);
    check(got.verdict == kNowObsNotFound && got.why == kNowObsWhyElementGone,
          "a window past the traversal bound is not found, not partially "
          "resolved");
}

static void verdicts_have_words(void)
{
    check(strcmp(now_obs_verdict_name(kNowObsOk), "ok") == 0, "ok");
    check(strcmp(now_obs_verdict_name(kNowObsNotFound), "not-found") == 0,
          "not-found");
    check(strcmp(now_obs_verdict_name(kNowObsAmbiguous), "ambiguous") == 0,
          "ambiguous");
    check(strcmp(now_obs_verdict_name(kNowObsMismatch), "mismatch") == 0,
          "mismatch");
    check(strcmp(now_obs_verdict_name(kNowObsStale), "stale") == 0, "stale");
    /* Every reason has a sentence; a refusal nobody can read is a refusal
       nobody can act on. */
    check(strcmp(now_obs_why_text(kNowObsWhyProcessRecycled),
                 now_obs_why_text(kNowObsWhyAddressesMoved)) != 0,
          "and the two Mismatch-adjacent reasons do not read alike");
}

int main(void)
{
    resolves();
    window_references_resolve();
    a_reopened_window_is_a_different_window();
    the_two_staleness_guards_are_independent();
    every_refusal_is_told_apart();
    a_cycle_is_refused();
    a_chain_longer_than_the_bound_is_refused();
    verdicts_have_words();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("obsresolve: all checks passed\n");
    return 0;
}
