/* Minting and looking up observation references. See obsref.h. */

#include "obsref.h"

#include <stdio.h>
#include <string.h>

/* FNV-1a, the same hash the ported fingerprint uses (axresolve.c). It is
   a CHANGE DETECTOR here as it is there, not a cryptographic primitive -
   what makes a token unguessable is the secret in the mix, not the mixer.
   Masked to 32 bits at every step so the host (64-bit long) and the
   PowerPC guest (32-bit long) compute the same value. */
static unsigned long mix32(unsigned long hash, unsigned long value)
{
    unsigned int byte;

    for (byte = 0; byte < 4; byte++) {
        hash ^= (value >> (byte * 8)) & 0xffUL;
        hash = (hash * 16777619UL) & 0xffffffffUL;
    }
    return hash;
}

static unsigned long token_word(unsigned long domain,
                                const NowObsRegistry *registry,
                                NowObsKind kind,
                                const NowObsIdentity *identity)
{
    unsigned long hash = 2166136261UL;

    hash = mix32(hash, domain);
    hash = mix32(hash, registry->seed_hi);
    hash = mix32(hash, registry->seed_lo);
    hash = mix32(hash, registry->counter);
    hash = mix32(hash, (unsigned long)kind);
    hash = mix32(hash, identity->psn_hi);
    hash = mix32(hash, identity->psn_lo);
    hash = mix32(hash, identity->process_fingerprint);
    hash = mix32(hash, identity->node_fingerprint);
    hash = mix32(hash, identity->window_address);
    hash = mix32(hash, identity->control_handle);
    /* The text route is part of the identity because it is part of the
       identity - two element references into the same window can differ
       in nothing else, and what a token is hashed over should be what a
       reference means.

       It is NOT what stops the two colliding, and saying so is worth the
       line: the counter above already differs on every mint, so no two
       tokens can be equal whatever else agrees. Removing these three
       mixes leaves every test green, which was checked rather than
       assumed. They are here for correctness of expression, not as a
       guard anything can fail. */
    hash = mix32(hash, identity->text_kind);
    hash = mix32(hash, identity->te_handle);
    hash = mix32(hash, (unsigned long)identity->dialog_item);
    return hash & 0xffffffffUL;
}

unsigned long now_obs_process_fingerprint(unsigned long psn_hi,
                                          unsigned long psn_lo,
                                          unsigned long signature,
                                          unsigned long launch_date,
                                          unsigned long partition_lo,
                                          unsigned long partition_size,
                                          const unsigned char *name)
{
    unsigned long hash = 2166136261UL;
    unsigned int  i;
    unsigned int  n;

    hash = mix32(hash, psn_hi);
    hash = mix32(hash, psn_lo);
    hash = mix32(hash, signature);
    hash = mix32(hash, launch_date);
    hash = mix32(hash, partition_lo);
    hash = mix32(hash, partition_size);
    n = (name != NULL) ? (unsigned int)name[0] : 0U;
    hash = mix32(hash, (unsigned long)n);
    for (i = 0; i < n; i++) {
        hash ^= name[1 + i];
        hash = (hash * 16777619UL) & 0xffffffffUL;
    }
    return hash & 0xffffffffUL;
}

void now_obs_registry_init(NowObsRegistry *registry, unsigned long seed_hi,
                           unsigned long seed_lo)
{
    if (registry == NULL) {
        return;
    }
    memset(registry, 0, sizeof(*registry));
    registry->seed_hi = seed_hi & 0xffffffffUL;
    registry->seed_lo = seed_lo & 0xffffffffUL;
}

void now_obs_registry_clear(NowObsRegistry *registry)
{
    unsigned long i;

    if (registry == NULL) {
        return;
    }
    for (i = 0; i < (unsigned long)kNowObsRegistryMax; i++) {
        memset(&registry->entries[i], 0, sizeof(registry->entries[i]));
    }
    registry->next = 0;
}

const char *now_obs_kind_prefix(NowObsKind kind)
{
    return (kind == kNowObsKindWindow) ? "now-window-" : "now-element-";
}

static int is_lower_hex(char c)
{
    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
}

/* The host validates this same shape before it forwards a reference
   (AgentIntegrationActPolicy.windowReferencePattern). Checking it again
   here is not distrust of the host: the console path reaches this layer
   without passing through it at all, and a layer that only holds when
   its caller is well-behaved is not holding anything. */
int now_obs_token_valid(NowObsKind kind, const char *text, size_t len)
{
    static const int kDashAt[4] = { 8, 13, 18, 23 };
    const char *prefix = now_obs_kind_prefix(kind);
    size_t prefix_len;
    size_t i;
    int    d;

    if (text == NULL) {
        return 0;
    }
    prefix_len = strlen(prefix);
    if (len != prefix_len + 36 || memcmp(text, prefix, prefix_len) != 0) {
        return 0;
    }
    for (i = 0; i < 36; i++) {
        char c = text[prefix_len + i];
        int  is_dash = 0;

        for (d = 0; d < 4; d++) {
            if ((int)i == kDashAt[d]) {
                is_dash = 1;
            }
        }
        if (is_dash) {
            if (c != '-') {
                return 0;
            }
        } else if (!is_lower_hex(c)) {
            return 0;
        }
    }
    return 1;
}

static int format_token(char *out, size_t cap, NowObsKind kind,
                        unsigned long w0, unsigned long w1,
                        unsigned long w2, unsigned long w3)
{
    int n = snprintf(out, cap, "%s%08lx-%04lx-%04lx-%04lx-%04lx%08lx",
                     now_obs_kind_prefix(kind),
                     w0 & 0xffffffffUL,
                     (w1 >> 16) & 0xffffUL, w1 & 0xffffUL,
                     (w2 >> 16) & 0xffffUL, w2 & 0xffffUL,
                     w3 & 0xffffffffUL);

    return (n > 0 && (size_t)n < cap) ? 1 : 0;
}

unsigned long now_obs_epoch_begin(NowObsRegistry *registry)
{
    if (registry == NULL) {
        return 0;
    }
    registry->epochs++;
    /* Never 0: 0 is the sentinel for "no walk open", and an epoch that
       wrapped onto it would make every entry it stamped permanently
       un-evictable. */
    registry->epoch = registry->epochs;
    if (registry->epoch == 0) {
        registry->epochs = 1;
        registry->epoch = 1;
    }
    return registry->epoch;
}

void now_obs_epoch_end(NowObsRegistry *registry)
{
    if (registry != NULL) {
        registry->epoch = 0;
    }
}

/* Everything a reference MEANS, compared field by field. minted_ticks is
   excluded and is the only exclusion: it is when an observation happened,
   not what it saw, and including it would make interning impossible -
   every walk reads a different tick. */
static int identity_same(const NowObsIdentity *a, const NowObsIdentity *b)
{
    if (a->psn_hi != b->psn_hi || a->psn_lo != b->psn_lo
        || a->process_fingerprint != b->process_fingerprint
        || a->node_fingerprint != b->node_fingerprint
        || a->window_address != b->window_address
        || a->control_handle != b->control_handle
        || a->text_kind != b->text_kind
        || a->te_handle != b->te_handle
        || a->dialog_item != b->dialog_item) {
        return 0;
    }
    if (a->ref.window_occurrence != b->ref.window_occurrence
        || a->ref.control_occurrence != b->ref.control_occurrence
        || a->ref.window_title_len != b->ref.window_title_len
        || a->ref.control_title_len != b->ref.control_title_len) {
        return 0;
    }
    if (memcmp(a->ref.window_title, b->ref.window_title,
               a->ref.window_title_len) != 0) {
        return 0;
    }
    return memcmp(a->ref.control_title, b->ref.control_title,
                  a->ref.control_title_len) == 0;
}

/* The slot the next mint takes, or NULL when an open epoch has spoken
   for all of them. Round-robin from the cursor, exactly as before; the
   only new rule is that a slot this walk already minted or reused is not
   a candidate, so a walk cannot eat its own references. */
static NowObsEntry *evictable_slot(NowObsRegistry *registry)
{
    unsigned long tried;

    for (tried = 0; tried < (unsigned long)kNowObsRegistryMax; tried++) {
        NowObsEntry *slot = &registry->entries[registry->next];

        registry->next = (registry->next + 1)
                         % (unsigned long)kNowObsRegistryMax;
        if (registry->epoch != 0 && slot->used
            && slot->epoch == registry->epoch) {
            continue;
        }
        return slot;
    }
    return NULL;
}

int now_obs_intern(NowObsRegistry *registry, NowObsKind kind,
                   const NowObsIdentity *identity, char *out, size_t cap)
{
    unsigned long i;

    if (registry == NULL || identity == NULL || out == NULL
        || cap < kNowObsTokenMax) {
        return 0;
    }
    for (i = 0; i < (unsigned long)kNowObsRegistryMax; i++) {
        NowObsEntry *entry = &registry->entries[i];

        if (!entry->used || entry->kind != (unsigned char)kind) {
            continue;
        }
        if (!identity_same(&entry->identity, identity)) {
            continue;
        }
        /* Stamped, so the rest of this walk cannot evict the entry it is
           about to hand a caller. */
        entry->epoch = registry->epoch;
        registry->reused++;
        memcpy(out, entry->token, strlen(entry->token) + 1);
        return 1;
    }
    return now_obs_mint(registry, kind, identity, out, cap);
}

int now_obs_mint(NowObsRegistry *registry, NowObsKind kind,
                 const NowObsIdentity *identity, char *out, size_t cap)
{
    char          token[kNowObsTokenMax];
    NowObsEntry  *slot;
    unsigned long w0;
    unsigned long w1;
    unsigned long w2;
    unsigned long w3;

    if (registry == NULL || identity == NULL || out == NULL
        || cap < kNowObsTokenMax) {
        return 0;
    }
    /* The slot is chosen BEFORE the counter moves. A mint that cannot be
       filed must not consume a token number: the counter is what makes
       two mints of the same identity differ, and burning one on a
       refusal would make the registry's own statistics lie about how
       many references it ever produced. */
    slot = evictable_slot(registry);
    if (slot == NULL) {
        return 0;
    }
    registry->counter++;
    w0 = token_word(0UL, registry, kind, identity);
    w1 = token_word(1UL, registry, kind, identity);
    w2 = token_word(2UL, registry, kind, identity);
    w3 = token_word(3UL, registry, kind, identity);
    if (!format_token(token, sizeof(token), kind, w0, w1, w2, w3)) {
        return 0;
    }

    /* Round-robin, oldest slot first (evictable_slot advanced the cursor
       already). An evicted token is gone, not recycled: the slot is
       overwritten wholesale, so the old string never matches again and
       its caller is told NotFound rather than being pointed at whatever
       now lives there. */
    if (slot->used) {
        registry->evicted++;
    }
    memset(slot, 0, sizeof(*slot));
    slot->used = 1;
    slot->kind = (unsigned char)kind;
    memcpy(slot->token, token, strlen(token) + 1);
    slot->identity = *identity;
    slot->epoch = registry->epoch;
    registry->minted++;

    memcpy(out, token, strlen(token) + 1);
    return 1;
}

const NowObsEntry *now_obs_lookup(const NowObsRegistry *registry,
                                  NowObsKind kind, const char *text,
                                  size_t len)
{
    unsigned long i;

    if (registry == NULL || !now_obs_token_valid(kind, text, len)) {
        return NULL;
    }
    for (i = 0; i < (unsigned long)kNowObsRegistryMax; i++) {
        const NowObsEntry *entry = &registry->entries[i];

        if (!entry->used || entry->kind != (unsigned char)kind) {
            continue;
        }
        if (strlen(entry->token) == len
            && memcmp(entry->token, text, len) == 0) {
            return entry;
        }
    }
    return NULL;
}
