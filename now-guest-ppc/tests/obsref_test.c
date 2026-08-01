/* Native test for reference minting and matching - the pure half of the
   layer every act verb addresses.

       cc -Wall -Wextra -Werror -I ../src/observe -I ../src/axwalk \
          -I ../src/peek obsref_test.c ../src/observe/obsref.c \
          ../src/axwalk/axresolve.c ../src/axwalk/axwalk.c \
          ../src/peek/peek_validate.c -o obsref_test && ./obsref_test

   WHAT THIS TEST IS ACTUALLY GUARDING. Mirror measured that an act
   surface bounded by time or by use count is not bounded at all (18/20
   hijacked), and that one bounded by NAMING ITS TARGET is (0/20). The
   whole of that result rests on a caller being unable to name a target
   it did not observe. So the assertions below are mostly negative: that
   the same identity does not mint the same token twice, that a different
   session cannot reproduce another session's tokens, and that a token
   nobody minted matches nothing. A test that only checked "mint then
   look up returns the entry" would pass against a scheme where the token
   was the window title. */

#include <stdio.h>
#include <string.h>

#include "obsref.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

static void identity_for(NowObsIdentity *id, unsigned long window,
                         unsigned long control, const char *win_title,
                         const char *ctl_title)
{
    memset(id, 0, sizeof(*id));
    id->psn_hi = 0;
    id->psn_lo = 0x12345UL;
    id->process_fingerprint = 0xABCD1234UL;
    id->window_address = window;
    id->control_handle = control;
    id->node_fingerprint = now_ax_ref_fingerprint(id->psn_hi, id->psn_lo,
                                                  window, control);
    id->ref.psn_hi = id->psn_hi;
    id->ref.psn_lo = id->psn_lo;
    strcpy((char *)id->ref.window_title, win_title);
    id->ref.window_title_len = strlen(win_title);
    strcpy((char *)id->ref.control_title, ctl_title);
    id->ref.control_title_len = strlen(ctl_title);
    id->ref.node_fingerprint = id->node_fingerprint;
}

/* The shape the host already validates and already tests thirteen
   spellings of "frontmost" against. If this drifts, every act row on the
   other side starts rejecting references this guest mints, and the
   symptom would be a host-side regex failure pointing nowhere near here. */
static void token_shape(void)
{
    NowObsRegistry registry;
    NowObsIdentity id;
    char           token[kNowObsTokenMax];
    size_t         len;

    now_obs_registry_init(&registry, 0x0BADF00DUL, 0xFEEDFACEUL);
    identity_for(&id, 0x00101000UL, 0x00108000UL, "Save", "OK");

    check(now_obs_mint(&registry, kNowObsKindElement, &id, token,
                       sizeof(token)) == 1, "an element mints");
    len = strlen(token);
    check(len == strlen("now-element-") + 36, "token is prefix plus a UUID");
    check(memcmp(token, "now-element-", 12) == 0, "element prefix");
    check(token[12 + 8] == '-' && token[12 + 13] == '-'
          && token[12 + 18] == '-' && token[12 + 23] == '-',
          "dashes sit at 8-4-4-4-12");
    check(now_obs_token_valid(kNowObsKindElement, token, len) == 1,
          "the minted token validates as an element reference");
    check(now_obs_token_valid(kNowObsKindWindow, token, len) == 0,
          "and NOT as a window reference - the kinds are not interchangeable");

    check(now_obs_mint(&registry, kNowObsKindWindow, &id, token,
                       sizeof(token)) == 1, "a window mints");
    check(memcmp(token, "now-window-", 11) == 0, "window prefix");
    check(now_obs_token_valid(kNowObsKindWindow, token, strlen(token)) == 1,
          "and validates as a window reference");
}

static void malformed_is_refused(void)
{
    const char *bad[] = {
        "",
        "now-element-",
        "now-element-0123456789abcdef0123456789abcdef",   /* no dashes */
        /* Correctly SHAPED and uppercase, so this case tests the case
           rule rather than the layout rule. The host requires lowercase
           (isValidReference compares against value.lowercased()), so a
           guest that minted or accepted mixed case would mint references
           the other side rejects. */
        "now-element-01234567-89AB-CDEF-0123-456789ABCDEF",
        "now-element-0123456g-0123-0123-0123-0123456789ab",    /* not hex */
        "now-element-01234567-0123-0123-0123-0123456789ab-",   /* too long */
        "now-elemen-01234567-0123-0123-0123-0123456789ab",     /* prefix */
        "01234567-0123-0123-0123-0123456789ab"                 /* bare uuid */
    };
    unsigned int i;

    for (i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        check(now_obs_token_valid(kNowObsKindElement, bad[i],
                                  strlen(bad[i])) == 0,
              "a malformed reference is refused by shape alone");
    }
    check(now_obs_token_valid(kNowObsKindElement, NULL, 0) == 0,
          "NULL is refused");
    /* A well-formed one, so the checks above are not passing vacuously. */
    check(now_obs_token_valid(kNowObsKindElement,
                              "now-element-01234567-89ab-cdef-0123-456789abcdef",
                              48) == 1,
          "a well-formed reference passes the same check");
}

/* THE property. Everything a caller can see about an element - its
   title, its position, its WindowPtr, its process - is in `id`, and it
   is identical in both registries. Only the seed differs. If the tokens
   ever match, the token is derivable from observable state and a caller
   that never observed the element can name it. */
static void a_token_cannot_be_derived(void)
{
    NowObsRegistry a;
    NowObsRegistry b;
    NowObsIdentity id;
    char           token_a[kNowObsTokenMax];
    char           token_b[kNowObsTokenMax];

    identity_for(&id, 0x00101000UL, 0x00108000UL, "Save", "OK");
    now_obs_registry_init(&a, 0x11111111UL, 0x22222222UL);
    now_obs_registry_init(&b, 0x33333333UL, 0x44444444UL);
    check(now_obs_mint(&a, kNowObsKindElement, &id, token_a,
                       sizeof(token_a)) == 1, "mints in session A");
    check(now_obs_mint(&b, kNowObsKindElement, &id, token_b,
                       sizeof(token_b)) == 1, "mints in session B");
    check(strcmp(token_a, token_b) != 0,
          "the SAME element mints different tokens under different seeds");
    check(now_obs_lookup(&b, kNowObsKindElement, token_a,
                         strlen(token_a)) == NULL,
          "and session A's token means nothing to session B");
}

static void every_mint_is_new(void)
{
    NowObsRegistry registry;
    NowObsIdentity id;
    char           first[kNowObsTokenMax];
    char           second[kNowObsTokenMax];

    now_obs_registry_init(&registry, 0x0BADF00DUL, 0xFEEDFACEUL);
    identity_for(&id, 0x00101000UL, 0x00108000UL, "Save", "OK");
    check(now_obs_mint(&registry, kNowObsKindElement, &id, first,
                       sizeof(first)) == 1, "first mint");
    check(now_obs_mint(&registry, kNowObsKindElement, &id, second,
                       sizeof(second)) == 1, "second mint");
    check(strcmp(first, second) != 0,
          "observing the same element twice mints two references");
    check(now_obs_lookup(&registry, kNowObsKindElement, first,
                         strlen(first)) != NULL, "the first still resolves");
    check(now_obs_lookup(&registry, kNowObsKindElement, second,
                         strlen(second)) != NULL, "so does the second");
}

static void lookup_returns_what_was_minted(void)
{
    NowObsRegistry     registry;
    NowObsIdentity     id;
    char               token[kNowObsTokenMax];
    const NowObsEntry *entry;

    now_obs_registry_init(&registry, 7UL, 9UL);
    identity_for(&id, 0x00101400UL, 0x00108010UL, "Save", "Cancel");
    id.minted_ticks = 4242UL;
    check(now_obs_mint(&registry, kNowObsKindElement, &id, token,
                       sizeof(token)) == 1, "mint");
    entry = now_obs_lookup(&registry, kNowObsKindElement, token,
                           strlen(token));
    check(entry != NULL, "the token resolves to its entry");
    if (entry != NULL) {
        check(entry->identity.window_address == 0x00101400UL,
              "the window address came back");
        check(entry->identity.control_handle == 0x00108010UL,
              "the control handle came back");
        check(entry->identity.minted_ticks == 4242UL, "and the mint tick");
        check(strcmp((const char *)entry->identity.ref.control_title,
                     "Cancel") == 0, "and the title it was minted for");
    }
}

/* A reference nobody minted resolves to nothing, and a guessed one is
   just an unminted one. Walking every token that differs from a real one
   in a single hex digit is the cheap version of "guess it". */
static void a_guess_matches_nothing(void)
{
    NowObsRegistry registry;
    NowObsIdentity id;
    char           token[kNowObsTokenMax];
    size_t         len;
    size_t         i;
    int            collisions = 0;

    now_obs_registry_init(&registry, 0x5EEDUL, 0xC0FFEEUL);
    identity_for(&id, 0x00101000UL, 0x00108000UL, "Save", "OK");
    check(now_obs_mint(&registry, kNowObsKindElement, &id, token,
                       sizeof(token)) == 1, "mint");
    len = strlen(token);
    for (i = strlen("now-element-"); i < len; i++) {
        char guess[kNowObsTokenMax];
        int  d;

        if (token[i] == '-') {
            continue;
        }
        memcpy(guess, token, len + 1);
        for (d = 0; d < 16; d++) {
            guess[i] = "0123456789abcdef"[d];
            if (guess[i] == token[i]) {
                continue;
            }
            if (now_obs_lookup(&registry, kNowObsKindElement, guess,
                               len) != NULL) {
                collisions++;
            }
        }
    }
    check(collisions == 0, "no near-miss of a live token resolves");
}

/* Eviction is a REFUSAL, not a reassignment: the point of the bound is
   that the guest cannot be made to hold references forever, and the
   failure mode to avoid is an old token quietly acquiring a new meaning
   when its slot is reused. */
static void eviction_refuses_rather_than_reassigns(void)
{
    NowObsRegistry registry;
    NowObsIdentity id;
    char           oldest[kNowObsTokenMax];
    char           token[kNowObsTokenMax];
    int            i;

    now_obs_registry_init(&registry, 1UL, 2UL);
    identity_for(&id, 0x00101000UL, 0x00108000UL, "Save", "OK");
    check(now_obs_mint(&registry, kNowObsKindElement, &id, oldest,
                       sizeof(oldest)) == 1, "mint the first");
    check(now_obs_lookup(&registry, kNowObsKindElement, oldest,
                         strlen(oldest)) != NULL, "it resolves");
    for (i = 0; i < kNowObsRegistryMax; i++) {
        identity_for(&id, 0x00101000UL + (unsigned long)i * 0x10UL,
                     0x00108000UL + (unsigned long)i * 0x10UL, "Save", "OK");
        check(now_obs_mint(&registry, kNowObsKindElement, &id, token,
                           sizeof(token)) == 1, "fill the table");
    }
    check(now_obs_lookup(&registry, kNowObsKindElement, oldest,
                         strlen(oldest)) == NULL,
          "the evicted token no longer resolves - to anything");
    check(registry.evicted > 0, "and the eviction was counted");

    /* Every slot must be reachable by the cursor, and each exactly once
       per pass. A cursor that wrapped one short would leave one slot
       never written and another written twice as often - the first is a
       reference that outlives the bound, which is the bound not
       existing, and neither shows up as a failed lookup. Counting is how
       it shows up. */
    now_obs_registry_init(&registry, 1UL, 2UL);
    for (i = 0; i < 2 * kNowObsRegistryMax; i++) {
        identity_for(&id, 0x00101000UL + (unsigned long)i * 0x10UL,
                     0x00108000UL + (unsigned long)i * 0x10UL, "Save", "OK");
        check(now_obs_mint(&registry, kNowObsKindElement, &id, token,
                           sizeof(token)) == 1, "fill the table twice");
    }
    check(registry.minted == (unsigned long)(2 * kNowObsRegistryMax),
          "every mint was counted");
    check(registry.evicted == (unsigned long)kNowObsRegistryMax,
          "two full passes evicted exactly one slot's worth - the cursor "
          "visits every slot, and each once");
}

/* The recycled-PSN discriminator. Everything about a relaunched
   application matches its predecessor - same PSN, same signature, same
   partition, same name - except when it started. */
static void process_fingerprint_separates_a_relaunch(void)
{
    unsigned char name[6];
    unsigned long first;
    unsigned long relaunched;
    unsigned long renamed;
    unsigned long unnamed;

    name[0] = 4;
    memcpy(name + 1, "Save", 4);
    first = now_obs_process_fingerprint(0UL, 0x12345UL, 0x4D414353UL,
                                        0x3B9ACA00UL, 0x00100000UL,
                                        0x00080000UL, name);
    relaunched = now_obs_process_fingerprint(0UL, 0x12345UL, 0x4D414353UL,
                                             0x3B9ACA01UL, 0x00100000UL,
                                             0x00080000UL, name);
    check(first != relaunched,
          "a relaunch into the same PSN and partition fingerprints "
          "differently");
    name[1] = 'C';
    renamed = now_obs_process_fingerprint(0UL, 0x12345UL, 0x4D414353UL,
                                          0x3B9ACA00UL, 0x00100000UL,
                                          0x00080000UL, name);
    check(first != renamed, "so does a different application name");
    unnamed = now_obs_process_fingerprint(0UL, 0x12345UL, 0x4D414353UL,
                                          0x3B9ACA00UL, 0x00100000UL,
                                          0x00080000UL, NULL);
    check(first != unnamed && unnamed != 0UL,
          "a caller with no name gets the weaker tuple, not an error");
    check(now_obs_process_fingerprint(0UL, 0x12345UL, 0x4D414353UL,
                                      0x3B9ACA00UL, 0x00100000UL,
                                      0x00080000UL, NULL) == unnamed,
          "and the fingerprint is a function of its arguments only");
}

/* --- interning, and the walk epoch --------------------------------------

   These two exist because a SCENE re-reads the same desktop whenever a
   person presses refresh. The properties below are what make that
   affordable; each is written as the failure it prevents. */

/* Fetch the same element twice and it keeps its name - which is the
   whole point, because the name is in the JSON the person is looking at
   when they click. Note this is the OPPOSITE of every_mint_is_new above,
   deliberately: mint and intern are two readings of "a reference", and
   the caller picks. */
static void interning_is_stable(void)
{
    NowObsRegistry registry;
    NowObsIdentity id;
    char           first[kNowObsTokenMax];
    char           second[kNowObsTokenMax];

    now_obs_registry_init(&registry, 0x0BADF00DUL, 0xFEEDFACEUL);
    identity_for(&id, 0x00101000UL, 0x00108000UL, "Save", "OK");
    id.minted_ticks = 100UL;
    check(now_obs_intern(&registry, kNowObsKindElement, &id, first,
                         sizeof(first)) == 1, "first fetch mints");
    /* A later walk reads a later clock. If minted_ticks were part of
       identity nothing would ever intern, and the registry would grow by
       a whole scene on every refresh. */
    id.minted_ticks = 900UL;
    check(now_obs_intern(&registry, kNowObsKindElement, &id, second,
                         sizeof(second)) == 1, "second fetch interns");
    check(strcmp(first, second) == 0,
          "a second fetch of the same element carries the same reference");
    check(registry.minted == 1 && registry.reused == 1,
          "and the registry did not grow");
    check(now_obs_lookup(&registry, kNowObsKindElement, first,
                         strlen(first)) != NULL,
          "the reference the FIRST scene handed out still resolves");
}

/* What must NOT intern. Every field of the identity is part of what a
   reference means, so a reference must never be handed to an element
   that differs in any of them - the address that moved is the case that
   matters, because the title and occurrence still match and only the
   fingerprint disagrees. */
static void interning_refuses_a_different_element(void)
{
    NowObsRegistry registry;
    NowObsIdentity id;
    char           original[kNowObsTokenMax];
    char           other[kNowObsTokenMax];

    now_obs_registry_init(&registry, 3UL, 5UL);
    identity_for(&id, 0x00101000UL, 0x00108000UL, "Save", "OK");
    check(now_obs_intern(&registry, kNowObsKindElement, &id, original,
                         sizeof(original)) == 1, "mint the original");

    identity_for(&id, 0x00101000UL, 0x00108000UL, "Save", "Cancel");
    check(now_obs_intern(&registry, kNowObsKindElement, &id, other,
                         sizeof(other)) == 1, "a different title");
    check(strcmp(original, other) != 0, "does not inherit the reference");

    identity_for(&id, 0x00101000UL, 0x00109000UL, "Save", "OK");
    check(now_obs_intern(&registry, kNowObsKindElement, &id, other,
                         sizeof(other)) == 1, "the same button, moved");
    check(strcmp(original, other) != 0,
          "gets a new reference rather than the old one repaired");

    identity_for(&id, 0x00101000UL, 0x00108000UL, "Save", "OK");
    id.process_fingerprint = 0x99999999UL;
    check(now_obs_intern(&registry, kNowObsKindElement, &id, other,
                         sizeof(other)) == 1, "a relaunched process");
    check(strcmp(original, other) != 0, "does not inherit it either");

    identity_for(&id, 0x00101000UL, 0x00108000UL, "Save", "OK");
    check(now_obs_intern(&registry, kNowObsKindWindow, &id, other,
                         sizeof(other)) == 1, "and the other KIND");
    check(strcmp(original, other) != 0, "is a different reference");
}

/* The failure the epoch exists for: a walk longer than the registry
   evicting its own front while it is still emitting. Without the epoch
   the first tokens of this walk stop resolving before the walk ends, and
   nothing says so - the JSON carries them anyway. */
static void a_walk_does_not_evict_itself(void)
{
    NowObsRegistry registry;
    NowObsIdentity id;
    char           tokens[kNowObsRegistryMax][kNowObsTokenMax];
    char           overflow[kNowObsTokenMax];
    int            i;
    int            resolvable = 0;

    now_obs_registry_init(&registry, 11UL, 13UL);
    check(now_obs_epoch_begin(&registry) != 0, "an epoch is never 0");
    for (i = 0; i < kNowObsRegistryMax; i++) {
        identity_for(&id, 0x00101000UL, 0x00108000UL + (unsigned long)i * 4UL,
                     "Save", "OK");
        check(now_obs_intern(&registry, kNowObsKindElement, &id, tokens[i],
                             sizeof(tokens[i])) == 1, "a walk fills the table");
    }
    /* One past the table. It is REFUSED, and a refusal is a key the
       producer leaves absent - not a reference that costs an earlier
       one. */
    identity_for(&id, 0x00101000UL, 0x00200000UL, "Save", "OK");
    check(now_obs_intern(&registry, kNowObsKindElement, &id, overflow,
                         sizeof(overflow)) == 0,
          "past the table the walk gets NO reference");
    for (i = 0; i < kNowObsRegistryMax; i++) {
        if (now_obs_lookup(&registry, kNowObsKindElement, tokens[i],
                           strlen(tokens[i])) != NULL) {
            resolvable++;
        }
    }
    check(resolvable == kNowObsRegistryMax,
          "and every reference the walk did hand out still resolves");
    now_obs_epoch_end(&registry);

    /* Closed, the entries are ordinary again: the NEXT walk may evict
       them. A registry that protected them forever would be a table that
       fills once and then refuses everything. */
    identity_for(&id, 0x00202000UL, 0x00202004UL, "Later", "Go");
    check(now_obs_mint(&registry, kNowObsKindElement, &id, overflow,
                       sizeof(overflow)) == 1,
          "and a later walk can reuse the slots");
}

/* With no epoch open, eviction is the plain round robin it always was -
   so the observe walk, which opens none, behaves exactly as before. */
static void no_epoch_is_the_old_behaviour(void)
{
    NowObsRegistry registry;
    NowObsIdentity id;
    char           first[kNowObsTokenMax];
    char           token[kNowObsTokenMax];
    int            i;

    now_obs_registry_init(&registry, 17UL, 19UL);
    identity_for(&id, 0x00101000UL, 0x00108000UL, "Save", "OK");
    check(now_obs_mint(&registry, kNowObsKindElement, &id, first,
                       sizeof(first)) == 1, "the first mint");
    for (i = 0; i < kNowObsRegistryMax; i++) {
        identity_for(&id, 0x00101000UL,
                     0x00300000UL + (unsigned long)i * 4UL, "Save", "OK");
        check(now_obs_mint(&registry, kNowObsKindElement, &id, token,
                           sizeof(token)) == 1,
              "and a table's worth after it");
    }
    check(now_obs_lookup(&registry, kNowObsKindElement, first,
                         strlen(first)) == NULL,
          "the oldest reference was evicted, not refused");
}

int main(void)
{
    token_shape();
    malformed_is_refused();
    a_token_cannot_be_derived();
    every_mint_is_new();
    lookup_returns_what_was_minted();
    a_guess_matches_nothing();
    eviction_refuses_rather_than_reassigns();
    process_fingerprint_separates_a_relaunch();
    interning_is_stable();
    interning_refuses_a_different_element();
    a_walk_does_not_evict_itself();
    no_epoch_is_the_old_behaviour();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("obsref: all checks passed\n");
    return 0;
}
