#ifndef NOW_OBSREF_H
#define NOW_OBSREF_H

/* Observation-minted references: what an act verb is allowed to name.

   WHY THIS EXISTS AT ALL, in one paragraph, because every design choice
   below follows from it. Mirror measured two variants of the same act
   surface against a live guest: a request that merely DISARMED after one
   use rode the user's own press 18 times out of 20, and the variant that
   additionally required the request to name its exact target hijacked 0
   out of 20. A bound on time or on count is not a bound on scope. So an
   act names ONE element, and the only way to name one is to have
   observed it - there is no spelling here for "whatever is frontmost".

   WHAT A REFERENCE IS MADE OF. On the wire it is exactly what the host
   already publishes and already tests for (MirrorActModels.swift):

       now-window-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
       now-element-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

   - lowercase hex in UUID layout. That string carries NO identity: it is
   a LOOKUP KEY into this registry, and the identity it stands for
   (process, window title and occurrence, control title and occurrence,
   and the address fingerprints both were minted against) lives only on
   this side, in a table only an observation writes.

   WHY IT CANNOT BE FORGED. Three independent reasons, and the first is
   the load-bearing one:

   1. THE TOKEN IS NOT DERIVED FROM ANYTHING A CALLER KNOWS. Its 128 bits
      are an FNV-1a mix over a per-session secret seed the caller never
      sees, a mint counter, and the identity. Knowing the window title,
      the coordinates, the WindowPtr, and every other observable fact
      about an element does not let anyone compute its token, because the
      seed is not among them.
   2. A TOKEN THAT WAS NEVER MINTED RESOLVES TO NOTHING. Lookup is exact
      string match against a table whose only writer is a walk that
      actually saw the element. A guessed token misses; a token from a
      previous run of the guest misses (new seed, empty table).
   3. THE IDENTITY BEHIND IT IS RE-CHECKED, NOT TRUSTED. See obsresolve.h.
      The table records what was true at mint; resolution proves it again
      from foreign memory and refuses if it has changed.

   A COORDINATE IS NOT A REFERENCE, and this is the property to protect
   in review. Nothing here accepts an x/y, a z-order index, a WindowPtr,
   or a title as an alternative spelling for a token. If a future caller
   can reconstruct a reference from where something is on the screen, the
   18/20 defect is back in NOW's idiom, whatever the field is called.

   Pure: no Toolbox, no allocation, no clock. The seed and the identity
   numbers are arguments, which is what makes minting and matching - the
   half that has to be right - reachable from a host test. */

#include <stddef.h>

#include "axresolve.h"

enum {
    /* "now-element-" (12) + 36 + NUL, rounded up. The window prefix is
       shorter, so one buffer serves both. */
    kNowObsTokenMax = 56,

    /* Live references the guest will hold at once. An observation of a
       busy machine mints one per control, so this is the real bound on
       how much of a walk stays addressable; past it the oldest slot is
       reused and its token stops resolving (NotFound, never a silent
       re-aim at whatever now occupies the slot). */
    kNowObsRegistryMax = 96
};

typedef enum {
    kNowObsKindWindow = 0,
    kNowObsKindElement = 1
} NowObsKind;

/* HOW A TEXT ELEMENT IS REACHED once its reference has resolved. An
   element reference names one of two things and the registry has to
   remember which: a CONTROL, which carries a live ControlHandle, or a
   TEXT element, which carries none and is reached through its window.
   The act plane's textget/textset need the route, so the route is minted
   with the reference rather than re-derived at act time - re-deriving it
   would be a second thing deciding what an element is.

   The values mirror the resident plane's kNowPeekActText* so nothing has
   to translate twice. */
enum {
    kNowObsTextNone = 0,        /* a control, or a window */
    kNowObsTextDitem = 1,       /* a dialog item, by 1-based index */
    kNowObsTextTe = 2,          /* a TEHandle the observation read */
    kNowObsTextDialogTe = 3     /* the dialog's own TextEdit record */
};

/* Everything the mint knew, so resolution can prove it again.

   `process_fingerprint` is the discriminator a PSN alone cannot be: Mac
   OS reuses process serial numbers, and a reference held across a quit
   and a relaunch would otherwise resolve cleanly against the WRONG
   application. It mixes the Process Manager's own launch date and
   signature with the partition bounds and the name, none of which
   survive into a recycled PSN together.

   `node_fingerprint` is the other axis: the ADDRESSES this element had.
   Titles and occurrences name an element the way a person would, which
   is exactly why they survive a redraw and exactly why they can start
   naming a different element after the window list changes. */
typedef struct {
    unsigned long psn_hi;
    unsigned long psn_lo;
    unsigned long process_fingerprint;
    unsigned long node_fingerprint;
    unsigned long window_address;
    unsigned long control_handle;   /* 0 for a window or a text element */
    unsigned long minted_ticks;
    /* The text route, for an element reference that names a text element
       rather than a control. kNowObsTextNone everywhere else, which is
       also what tells the act plane that ctlact may have this one and
       textset may not. */
    unsigned long text_kind;        /* kNowObsText* */
    unsigned long te_handle;        /* kNowObsTextTe only */
    long          dialog_item;      /* kNowObsTextDitem only, 1-based */
    NowAxRef      ref;              /* titles and occurrences */
} NowObsIdentity;

typedef struct {
    unsigned char  used;
    unsigned char  kind;
    char           token[kNowObsTokenMax];
    NowObsIdentity identity;
    /* The walk epoch that last minted or reused this entry, or 0 for an
       entry no epoch has touched. See now_obs_epoch_begin. */
    unsigned long  epoch;
} NowObsEntry;

typedef struct {
    NowObsEntry   entries[kNowObsRegistryMax];
    unsigned long seed_hi;          /* the per-session secret */
    unsigned long seed_lo;
    unsigned long counter;          /* mints so far, for uniqueness */
    unsigned long next;             /* round-robin eviction cursor */
    unsigned long minted;           /* statistics, for the diagnostics */
    unsigned long evicted;
    unsigned long reused;           /* interned rather than minted */
    unsigned long epoch;            /* the OPEN walk, or 0 for none */
    unsigned long epochs;           /* walks opened so far */
} NowObsRegistry;

/* The process-identity fingerprint - the thing a PSN is not.

   Mac OS reuses process serial numbers. A reference minted against
   "PSN 0/12345" and resolved after that application quit and another
   launched into the same slot would resolve CLEANLY against the wrong
   program, which is the worst failure this layer can have: not a
   refusal, not a crash, a confident act on a stranger. So identity is
   the whole tuple.

   `launch_date` is the discriminator that does the work. It is the
   Process Manager's own launch timestamp, it is not derived from any
   address, and a relaunch cannot inherit it - unlike the partition
   bounds, the signature and the name, all of which a same-application
   relaunch reproduces exactly. Callers with no launch date pass 0 and
   get the weaker tuple rather than an error, in the same spirit as the
   oracle's optional V3 name.

   `name` is an optional Pascal string (NULL for none). */
unsigned long now_obs_process_fingerprint(unsigned long psn_hi,
                                          unsigned long psn_lo,
                                          unsigned long signature,
                                          unsigned long launch_date,
                                          unsigned long partition_lo,
                                          unsigned long partition_size,
                                          const unsigned char *name);

/* Arms a registry with this session's secret. Called once, with the
   least predictable numbers the caller can obtain; a caller that passes
   two constants gets a registry whose tokens are reproducible, which is
   a test fixture and never a live guest. */
void now_obs_registry_init(NowObsRegistry *registry, unsigned long seed_hi,
                           unsigned long seed_lo);

/* The wire prefix for a kind ("now-window-" / "now-element-"). */
const char *now_obs_kind_prefix(NowObsKind kind);

/* Shape check only - does this text spell a reference of this kind?
   Exactly the host's published pattern: the prefix, then 36 characters
   of lowercase hex in 8-4-4-4-12 layout. Says nothing about whether the
   reference names anything; that is now_obs_lookup's answer, and keeping
   the two apart is why a malformed reference and an expired one can be
   refused with different sentences. */
int now_obs_token_valid(NowObsKind kind, const char *text, size_t len);

/* Mints a reference for `identity` and writes its token to `out`.
   Returns 1 on success, 0 if out is too small, an argument is NULL, or
   an open walk epoch has already spoken for every slot (see below).
   Every call mints a NEW token, even for an identity already in the
   table: a reference is a receipt for one observation, not a name. The
   caller that wants the other reading asks for now_obs_intern. */
int now_obs_mint(NowObsRegistry *registry, NowObsKind kind,
                 const NowObsIdentity *identity, char *out, size_t cap);

/* --- a walk epoch, and interning ---------------------------------------

   WHY THESE EXIST, and it is a capacity argument rather than a taste
   one. The registry holds kNowObsRegistryMax references. A SCENE carries
   up to 64 windows and 96 controls, and a person refreshes a scene by
   pressing a button - so a producer that minted a fresh token for every
   element of every scene would (a) evict the front of a large scene
   while still encoding its back, handing out references that were
   already dead when the JSON left, and (b) invalidate the whole of the
   previous scene on every refresh, which is the scene the person is
   looking at when they click.

   Neither is fixed by making the table bigger; both are fixed by the two
   calls below.

   INTERNING. now_obs_intern reuses the entry whose identity is EXACTLY
   this one - same process, same fingerprints, same addresses, same title
   and occurrence, same text route - and mints only when there is none.
   That is not a weakening of "a reference is minted by an observation":
   the identity it matches was written by a walk that saw the element,
   the token is still unguessable, and resolution still re-proves the
   identity from foreign memory and still refuses rather than repairs.
   What it drops is the older "a reference is a receipt for ONE
   observation" reading - deliberately, and only for the caller that
   asks for it. now_obs_mint still mints unconditionally, and the
   observe walk still uses it: a caller enumerating a tree for a human
   wants a receipt, and a caller re-reading the same desktop twelve
   times a minute wants the same address to keep the same name.

   Note what interning does NOT freshen: the reused entry keeps the
   minted_ticks of the observation that first saw the element, because
   that is when this reference was minted.

   THE EPOCH. Round-robin eviction has no idea that the mint it is about
   to overwrite happened four elements ago in the SAME walk. Between
   now_obs_epoch_begin and now_obs_epoch_end, a slot minted or reused
   under the open epoch is not an eviction candidate; when every slot is
   spoken for, now_obs_mint REFUSES (returns 0) instead of eating its own
   walk. A caller that gets 0 has no reference for that element and must
   leave the key absent - which reads as "not minted", which is true.
   Epoch 0 means no walk is open and eviction is the plain round robin,
   so a caller that never opens one behaves exactly as before. */

/* Opens a walk epoch and returns its number (never 0). A second call
   without an end simply renumbers - there is one cooperative thread
   here, so nested walks are a bug rather than a case to serve. */
unsigned long now_obs_epoch_begin(NowObsRegistry *registry);

/* Closes the open epoch. The entries keep their stamp; what changes is
   that they become evictable again. */
void now_obs_epoch_end(NowObsRegistry *registry);

/* Mints, or hands back the token of the entry that already names this
   exact identity. Returns 1 with `out` set, or 0 - and then there is NO
   reference for this element and its key belongs absent. */
int now_obs_intern(NowObsRegistry *registry, NowObsKind kind,
                   const NowObsIdentity *identity, char *out, size_t cap);

/* The entry this token names, or NULL - never minted, evicted, or the
   wrong kind. Exact match; no prefix, fuzzy or nearest-neighbour
   lookup exists, deliberately. */
const NowObsEntry *now_obs_lookup(const NowObsRegistry *registry,
                                  NowObsKind kind, const char *text,
                                  size_t len);

/* Drops every reference. The honest thing to call when the machine
   changes underneath every one of them at once. */
void now_obs_registry_clear(NowObsRegistry *registry);

#endif /* NOW_OBSREF_H */
