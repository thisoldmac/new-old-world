#ifndef NOW_PEEK_TABLE_H
#define NOW_PEEK_TABLE_H

/* The NOW Extension's shared table - the in-memory contract between
   the 68K extension and the PPC application.
   ------------------------------------------------------------------
   This header is compiled by THREE compilers: the Retro68 68K build of
   the extension, the retrocarbon PPC build of the application, and the
   host cc for guest/tests/peek_table_test.c. It is the analogue of
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
    kNowPeekAnchorFormatV1 = 1
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
_Static_assert(sizeof(NowPeekAnchorSlot) == 24, "slot size");
_Static_assert(offsetof(NowPeekAnchorSlot, stamp_ticks) == 20,
               "slot stamp offset");
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
_Static_assert(sizeof(NowPeekTable) == 36 + 24 * kNowPeekMaxAnchors,
               "table size");

#endif /* NOW_PEEK_TABLE_H */
