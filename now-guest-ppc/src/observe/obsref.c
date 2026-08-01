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
    registry->counter++;
    w0 = token_word(0UL, registry, kind, identity);
    w1 = token_word(1UL, registry, kind, identity);
    w2 = token_word(2UL, registry, kind, identity);
    w3 = token_word(3UL, registry, kind, identity);
    if (!format_token(token, sizeof(token), kind, w0, w1, w2, w3)) {
        return 0;
    }

    /* Round-robin, oldest slot first. An evicted token is gone, not
       recycled: the slot is overwritten wholesale, so the old string
       never matches again and its caller is told NotFound rather than
       being pointed at whatever now lives there. */
    slot = &registry->entries[registry->next];
    if (slot->used) {
        registry->evicted++;
    }
    memset(slot, 0, sizeof(*slot));
    slot->used = 1;
    slot->kind = (unsigned char)kind;
    memcpy(slot->token, token, strlen(token) + 1);
    slot->identity = *identity;
    registry->next = (registry->next + 1)
                     % (unsigned long)kNowObsRegistryMax;
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
