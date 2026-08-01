#ifndef NOW_ACT_REF_H
#define NOW_ACT_REF_H

/* Opaque element references: the act plane's addressing, and the reason
   it cannot express "whatever is frontmost".

   WHY NOT A POINTER. A WindowPtr or a ControlHandle is an address in
   another process's heap. It is meaningful only while that element
   lives, it is trivially forgeable, and a caller holding one could name
   an element it never observed. So the plane takes the shape NOW
   already takes for processes: an opaque, short-lived string minted BY
   the observation that saw the element, which the RESPONDER maps back
   to a live element and revalidates before it acts.

   The spelling is the host's, stated in contract/asyncapi.yaml and in
   AgentIntegrationActPolicy: "now-window-" or "now-element-" followed
   by a UUID-shaped 8-4-4-4-12 of lowercase hex. The host validates the
   shape and forwards it; it deliberately does not resolve one, because
   a host-side match would be a stale observation wearing the clothes of
   a live one.

   WHAT A ROW REMEMBERS, and why it is not just an address. Addresses
   alone cannot tell "this window" from "a different window that was
   allocated where the old one was". So a row carries the addresses AND
   the identity axwalk already uses - title, occurrence, and the
   fingerprint from now_ax_ref_fingerprint(), which is a change detector
   over the addresses the reference was minted against. Revalidation
   re-walks the live window list and requires all of it to still agree;
   a reference whose title still resolves but whose addresses have moved
   is STALE, refused, and never resolved to the neighbour that happens
   to answer to the same name.

   Toolbox-free, like peek_oracle.c and scene_build.c: minting takes the
   four words it hashes as an argument rather than reading a clock, so
   every decision here is reachable from now_act_ref_test.c. */

#include <stddef.h>

#include "axwalk.h"

enum {
    /* "now-element-" (12) + 36 + NUL. The longer of the two prefixes
       sets the width; one buffer serves both so no caller has to know
       which kind it is holding. */
    kNowActRefMax = 12 + 36 + 1,

    /* How many live references the guest remembers at once. A scene of
       one machine's windows and their controls fits inside this with
       room; past it the oldest row is recycled, and a caller holding a
       recycled reference gets `not found`, which is the same answer it
       gets for a window that closed. Both are true and neither guesses. */
    kNowActRefSlots = 64
};

enum {
    kNowActRefWindow = 1,
    kNowActRefElement = 2
};

/* How a text element is reached once it has been resolved. Mirrors the
   resident plane's kNowPeekActText* so nothing has to translate twice. */
enum {
    kNowActTextNone = 0,
    kNowActTextDitem = 1,
    kNowActTextTe = 2,
    kNowActTextDialogTe = 3
};

typedef struct {
    char           ref[kNowActRefMax];
    unsigned short kind;                /* kNowActRefWindow / Element */
    unsigned short text_kind;           /* kNowActText* for an element */
    unsigned long  psn_hi;
    unsigned long  psn_lo;
    unsigned long  window_address;
    unsigned long  control_handle;      /* 0 for a window or a text field */
    unsigned long  te_handle;           /* kNowActTextTe only */
    long           dialog_item;         /* kNowActTextDitem only, 1-based */
    unsigned long  fingerprint;
    unsigned long  minted_ticks;
    unsigned char  title[kNowAxTitleMax + 1];
    size_t         title_len;
    unsigned int   occurrence;
} NowActRefRow;

typedef struct {
    NowActRefRow  rows[kNowActRefSlots];
    unsigned int  used;
    unsigned int  next;                 /* round-robin recycle cursor */
    unsigned long counter;              /* mixed into every mint */
} NowActRefTable;

void now_act_ref_reset(NowActRefTable *table);

/* Write the reference string for `kind` into `out`, from four words the
   caller supplies. Deterministic on purpose: a clock read inside here
   would put minting out of a test's reach, and the entropy this needs
   is uniqueness within one session, not unguessability - the host
   already refuses a reference it did not receive from an observation.

   Returns 1 on success, 0 if `cap` is too small to hold the whole
   thing. Never truncates: a half-written reference that still parses is
   the one failure this format must not have. */
int now_act_ref_format(unsigned short kind, const unsigned long words[4],
                       char *out, long cap);

/* Is this a well-formed reference of that kind? The same shape check
   the host makes, made again here - the guest does not trust the host
   to have validated an argument, and a typed caller can reach a guest
   directly. */
int now_act_ref_valid(unsigned short kind, const char *ref);

/* Remember `row` (its `ref` field is filled in) and return it. Recycles
   the oldest slot when full. `row->kind` decides the prefix. */
NowActRefRow *now_act_ref_remember(NowActRefTable *table,
                                   const NowActRefRow *row,
                                   unsigned long ticks);

/* The row this reference names, or NULL. An exact string match: a
   reference is either one this guest minted in this session or it is
   nothing at all. */
const NowActRefRow *now_act_ref_find(const NowActRefTable *table,
                                     const char *ref);

/* Does a freshly-walked element still match what the reference was
   minted against? The window address, the control handle and the
   fingerprint must ALL agree. Title and occurrence are how the element
   was FOUND again; this is how we know it is the same one. */
int now_act_ref_still_matches(const NowActRefRow *row,
                              unsigned long window_address,
                              unsigned long control_handle,
                              unsigned long fingerprint);

#endif /* NOW_ACT_REF_H */
