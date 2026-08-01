#ifndef NOW_PEEK_TABLE_H
#define NOW_PEEK_TABLE_H

/* The NOW Extension's shared table - the in-memory contract between
   the 68K extension and the PPC application.
   ------------------------------------------------------------------
   This header is compiled by THREE compilers: the Retro68 68K build of
   the extension, the retrocarbon PPC build of the application, and the
   host cc for now-guest-ppc/tests/peek_table_test.c. It is the analogue of
   asyncapi.yaml for the in-memory seam (docs/resident-components.md),
   and the same rule applies: every limit is stated here, once.

   Layout rules that keep three compilers honest (m68k gcc aligns
   32-bit fields to 2 bytes, PPC to 4 - the silent-drift trap):
     - every field is 32 bits, or 16-bit fields come in adjacent pairs,
       so every offset is naturally 4-aligned and NO compiler inserts
       padding;
     - the static asserts below pin every offset; a layout change that
       breaks them does not build anywhere.

   Discovery: the extension registers Gestalt selector 'NWex' at INIT
   time; the response is the table's address in the system heap. The
   application requires magic and an exact ext_major, and gates every
   read on length (accretive, the prefs-record rule) plus the owning
   plane's format word. Capabilities are bits, never inferred from
   versions - a plane can ship dark before it is metal-verified.

   Write discipline: the extension's filter writes every field except
   arm_request, which only the application writes. One writer per word,
   both sides big-endian (same machine), no locks; stamp fields are the
   ordering signal - a reader treats a slot as valid only when its
   stamp is nonzero and fresh enough for the reader's purpose.
   Freshness is per-slot and honest: anchors are captured when a
   process pumps its event loop, so a faceless or wedged app has an
   absent or stale slot - distinct states, both rendered truthfully. */

#ifdef NOW_PEEK_TABLE_HOST
#include <stdint.h>
typedef uint16_t NowPeekU16;
typedef uint32_t NowPeekU32;
#else
#include <MacTypes.h>
typedef UInt16 NowPeekU16;
typedef UInt32 NowPeekU32;
#endif

#include <stddef.h>

/* Spelled out so no compiler warns about multi-character constants. */
#define NOW_PEEK_4CC(a, b, c, d)                                      \
    (((NowPeekU32)(a) << 24) | ((NowPeekU32)(b) << 16)                \
     | ((NowPeekU32)(c) << 8) | (NowPeekU32)(d))

enum {
    /* Gestalt selector 'NWex'; response is the table address. */
    kNowPeekGestaltSelector = (long)NOW_PEEK_4CC('N', 'W', 'e', 'x'),
    /* First prelude field; a table without it is not a table. */
    kNowPeekTableMagic = (long)NOW_PEEK_4CC('N', 'W', 'p', 't'),

    /* Exact-match compatibility. Bump ONLY when an existing field's
       meaning changes; new fields ride on length instead. */
    kNowPeekExtMajor = 1,

    /* Matches the Process Manager walk's cap in processes_module.c;
       classic systems run a dozen-odd processes, 32 is headroom. */
    kNowPeekMaxAnchors = 32,

    kNowPeekAnchorFormatNone = 0, /* plane P1 absent (core-only M0) */
    kNowPeekAnchorFormatV1 = 1,   /* a5, window_list, menu_list */
    kNowPeekAnchorFormatV2 = 2,   /* + stack_base */
    kNowPeekAnchorFormatV3 = 3,   /* + cur_ap_name */

    /* Low memory's CurApName is a Str31 - one length byte plus up to 31
       characters - so 32 bytes holds it whole, with no truncation rule
       to get wrong on either side of the seam. 32 is also the only
       width that costs nothing: it is a multiple of 4, so the field
       after it stays naturally aligned and no compiler has to insert
       padding to reach it. A shorter field (say 28) would have to
       define what happens to a longer name, and every such definition
       is a way for two sides to disagree about identity - which is the
       one thing this field exists to settle. */
    kNowPeekAnchorNameSize = 32
};

/* Plane capability bits (caps, arm_request, arm_active). The guest's
   peek.h aliases these - state them once, here. */
enum {
    kNowPeekTableCapAnchors = 1u << 0,  /* P1: per-process anchors */
    kNowPeekTableCapTree = 1u << 1      /* P2: semantic-tree assist */
};

/* One process's anchors, captured by the jGNE filter while that
   process's context is current - the only place its low-memory
   Window/Menu state is visible (finding observe-process-local-ui).
   The extension publishes ADDRESSES only; following them into a
   foreign heap is application code, never resident code. */
typedef struct {
    NowPeekU32 psn_high;      /* ProcessSerialNumber; 0/0 = empty slot */
    NowPeekU32 psn_low;
    NowPeekU32 a5;            /* CurrentA5 for that context */
    NowPeekU32 window_list;   /* low-memory WindowList head */
    NowPeekU32 menu_list;     /* low-memory MenuList */
    NowPeekU32 stamp_ticks;   /* TickCount at capture; 0 = never */
    /* V2. APPENDED, deliberately: stamp_ticks stays at offset 20 because
       readers use it as a seqlock - stamp, fields, stamp again - and a V1
       reader still finds it exactly where it left it.

       Note the field's position says nothing about when it is WRITTEN.
       capture_anchor fills this BEFORE committing the stamp, like every
       other field, or a reader could pair a fresh stamp with a stale
       stack base and never know. */
    NowPeekU32 stack_base;    /* LMGetCurStackBase for that context */
    /* V3. Appended again, by the same rule and for the same reason: the
       seqlock's stamp keeps offset 20, stack_base keeps 24, and a V1 or
       V2 reader finds every field it knows exactly where it left it.

       The process's own name (low-memory CurApName), captured in the
       same context as A5 - which is what makes it worth carrying. A5
       and stack_base are both ADDRESSES, so a recycled slot left behind
       by a dead application whose partition was reused can satisfy both
       and still be debris. The name is not an address: it survives the
       reuse and names the dead application, which is a discriminator
       neither root can supply.

       A Pascal string: cur_ap_name[0] is the length, 0 meaning the
       extension had none to give. Written BEFORE the stamp commits,
       like every other field.

       Not a promise of uniqueness - two copies of the same application
       share a name - so it can only ever REFUTE a slot, never elect
       one. The oracle uses it that way. */
    unsigned char cur_ap_name[kNowPeekAnchorNameSize];
} NowPeekAnchorSlot;

typedef struct {
    NowPeekU32 magic;         /* kNowPeekTableMagic */
    NowPeekU16 ext_major;     /* exact match required */
    NowPeekU16 ext_minor;     /* informational */
    NowPeekU32 length;        /* bytes valid; readers gate on >= */
    NowPeekU32 caps;          /* planes present in this binary */
    NowPeekU32 heartbeat;     /* TickCount at last filter pass */
    NowPeekU32 boot_ticks;    /* TickCount when the core installed */
    NowPeekU32 arm_request;   /* application writes: plane bits to arm */
    NowPeekU32 arm_active;    /* extension writes: plane bits armed */
    NowPeekU16 anchor_format; /* kNowPeekAnchorFormat* */
    NowPeekU16 anchor_count;  /* slots the filter maintains */
    NowPeekAnchorSlot anchors[kNowPeekMaxAnchors];
} NowPeekTable;

/* The offsets ARE the contract; a drift here is a defect on the other
   side of a compiler, not a build detail. */
_Static_assert(sizeof(NowPeekAnchorSlot) == 60, "slot size");
/* Unchanged from V1 on purpose: this offset is the seqlock's, and moving
   it would break a V1 reader silently rather than loudly. */
_Static_assert(offsetof(NowPeekAnchorSlot, stamp_ticks) == 20,
               "slot stamp offset");
_Static_assert(offsetof(NowPeekAnchorSlot, stack_base) == 24,
               "slot stack base offset");
/* V3's field is appended, so V2's two offsets above are unchanged and
   this one is the only new number. 32 bytes of unsigned char at a
   4-aligned offset leaves the slot 4-aligned and 60 bytes wide on every
   one of the three compilers - no padding anywhere, which is the whole
   layout rule stated at the top of this file. */
_Static_assert(offsetof(NowPeekAnchorSlot, cur_ap_name) == 28,
               "slot name offset");
_Static_assert(sizeof(((NowPeekAnchorSlot *)0)->cur_ap_name)
                   == kNowPeekAnchorNameSize,
               "slot name width");
_Static_assert(offsetof(NowPeekTable, ext_major) == 4, "major offset");
_Static_assert(offsetof(NowPeekTable, ext_minor) == 6, "minor offset");
_Static_assert(offsetof(NowPeekTable, length) == 8, "length offset");
_Static_assert(offsetof(NowPeekTable, caps) == 12, "caps offset");
_Static_assert(offsetof(NowPeekTable, heartbeat) == 16,
               "heartbeat offset");
_Static_assert(offsetof(NowPeekTable, boot_ticks) == 20,
               "boot ticks offset");
_Static_assert(offsetof(NowPeekTable, arm_request) == 24,
               "arm request offset");
_Static_assert(offsetof(NowPeekTable, arm_active) == 28,
               "arm active offset");
_Static_assert(offsetof(NowPeekTable, anchor_format) == 32,
               "anchor format offset");
_Static_assert(offsetof(NowPeekTable, anchor_count) == 34,
               "anchor count offset");
_Static_assert(offsetof(NowPeekTable, anchors) == 36, "anchors offset");
_Static_assert(sizeof(NowPeekTable) == 36 + 60 * kNowPeekMaxAnchors,
               "table size");

#endif /* NOW_PEEK_TABLE_H */
