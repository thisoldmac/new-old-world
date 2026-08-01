#ifndef NOW_CONTENT_TABLE_H
#define NOW_CONTENT_TABLE_H

/* The content plane's shared block - P3 of the NOW Extension.
   ------------------------------------------------------------------
   The plane hooks QuickDraw's per-port bottleneck procedures on an
   armed application's window ports, and records what that application
   draws into a ring the host drains. It is the thing
   docs/resident-components.md calls "the riskiest class we would ever
   ship": this code executes at DRAW time inside another process.

   PROVENANCE. The mechanism is ported from this project's own prototype
   (timbottu/mirror, guest/extensions/qdpeek, and mirror/docs/QDPEEK-SPEC.md),
   where it was measured on a live mac99 guest. The rule that governs the
   crossing is the one now-guest-ppc/src/axwalk/ carries: THE MEASURED PARTS
   ARE EVIDENCE, NOT STYLE. Upstream's live proof is strong evidence about
   this mechanism and NOT a measurement of this binary. Nothing here has run
   on a Macintosh.

   What upstream measured, and is therefore kept exactly:
     - the ten bottleneck families and which counter each bumps;
     - the re-entrancy guard (a bottleneck's standard proc calls OTHER
       bottlenecks - StdText blits each glyph through StdBits - so only
       the top-level entry records; nested calls pass straight through);
     - install / uninstall / repair driven from the jGNE moment in the
       owning process's own context;
     - the record layouts below, and BITS carrying geometry only, never
       pixels.

   What is NOT upstream-measured and is stated as ours: the arm protocol
   (below), and the ring's tail handling (now_content_logic.c). Upstream's
   record mode never passed its own milestone, so the ring is code that has
   run nowhere; it is written to be testable on a host cc for that reason.

   THREE COMPILERS, one layout - the peek_table.h rule, restated because it
   binds here too: every field is 32 bits, or 16-bit fields come in adjacent
   pairs, so no compiler inserts padding, and the static asserts pin it. The
   ring RECORDS are the one place 16-bit fields stand alone; every record
   struct is therefore 2-aligned by construction and contains no 32-bit
   field except in the header, where it sits at a 4-aligned offset. */

#include "peek_table.h"

#ifdef NOW_PEEK_TABLE_HOST
#include <stdint.h>
typedef int16_t NowContentS16;
#else
typedef SInt16 NowContentS16;
#endif

typedef NowPeekU16 NowContentU16;
typedef NowPeekU32 NowContentU32;

/* TWO ADDITIONS TO peek_table.h THAT THIS PLANE NEEDS, and cannot make
   itself (that header is owned by another lane right now):

     1. a plane capability bit,
            kNowPeekTableCapContent = 1u << 2,
        beside kNowPeekTableCapAnchors and kNowPeekTableCapTree, and
            #define NOW_PEEK_TABLE_HAS_CAP_CONTENT 1
        so the shim below retires itself;

     2. one appended field at the END of NowPeekTable,
            NowPeekU32 content_block;   / * P3 block address, 0 = absent * /
        with _Static_assert(offsetof(NowPeekTable, content_block)
                            == 36 + 60 * kNowPeekMaxAnchors)
        and the table-size assert grown by 4.

   The second is how the application FINDS this block: the extension
   allocates it in the system heap and publishes its address there. It is
   appended, so it is accretive under the header's own prefs-record rule -
   a reader that predates it gates on `length` and never looks. No
   existing offset moves, so no existing reader changes.

   Until (1) lands, the shim keeps this plane compiling and testable. It
   is written to disappear on its own the moment the real bit arrives,
   rather than to become a second definition nobody notices. */
#ifndef NOW_PEEK_TABLE_HAS_CAP_CONTENT
enum { kNowPeekTableCapContent = 1u << 2 };
#endif

enum {
    /* 'NWcb' - the block's own magic, distinct from the table's. */
    kNowContentBlockMagic = (long)NOW_PEEK_4CC('N', 'W', 'c', 'b'),

    /* Plane format word. A reader requires an exact match AND
       length >= what it reads, the accretive prefs-record rule. */
    kNowContentFormatNone = 0,
    kNowContentFormatV1 = 1,

    /* THE ARM COMMIT WORD, and it is deliberately not 1.
       A zeroed block, a block from a stale build, and a block whose
       first words got scribbled all read as "not armed" unless this
       exact value is present. The sibling spike paid for the cheap
       version of this: a stale resident INIT read a newer reader's
       fields at the wrong offsets, saw a bare arm flag, and patched
       every port it met while the caller believed it had named one
       target (prototypes/qdprobe/README.md). A distinctive commit word
       does not fix version skew - the format word does that - but it
       removes the case where uninitialised memory means "yes". */
    kNowContentArmCommit = (long)NOW_PEEK_4CC('N', 'W', 'c', 'a'),

    /* v1 ring size. Upstream's sign-off number, kept: op rates are
       modest there (a keystroke is ~5 ops), so 64 KiB is generously
       sized. It is also the plane's whole cost when nothing is armed -
       see the note on the block's lifetime in now_content.c. */
    kNowContentRingCap = 65536,

    /* Inline text bytes per TEXT record; a longer run truncates, sets
       the flag, and still reports its true length. */
    kNowContentTextMax = 64,

    /* Simultaneously hooked window ports. Overflow is COUNTED, never
       silently dropped - skipped_ports is an honesty counter. */
    kNowContentMaxPorts = 16
};

/* mode: how the resident hooks behave once armed. Anything outside this
   range is read as OFF - fail closed, because mode arrives from another
   process's write. */
enum {
    kNowContentModeOff = 0,
    kNowContentModeCount = 1,   /* bump counters only */
    kNowContentModeRecord = 2   /* count + append ring records */
};

/* Committed operations by bottleneck family, then the honesty counters.
   The families and their meanings are upstream's, unchanged; the four
   refusal counters are this port's, and they exist so a MISADDRESSED
   arm request is loud rather than silent. */
typedef struct {
    NowContentU32 text, line, rect, rrect, oval, arc, poly, rgn, bits, comment;
    NowContentU32 other;         /* a hooked proc with no dedicated counter */
    NowContentU32 dropped;       /* record did not fit the ring            */
    NowContentU32 skipped_ports; /* not a colour port / already hooked /
                                    port table full / app has its own procs */
    NowContentU32 installs, uninstalls, repairs, arms;
    /* Refusals. Each names a DIFFERENT way a request failed to say whose
       ports it wants, which is the distinction the plane exists to keep. */
    NowContentU32 refused_no_target;      /* armed, named no A5 world      */
    NowContentU32 refused_wrong_context;  /* named an A5 that is not this  */
    NowContentU32 refused_expired;        /* deadline passed / absent      */
    NowContentU32 retires;                /* requests aged out by the ext  */
} NowContentCounters;

typedef struct {
    NowContentU32 magic;        /* kNowContentBlockMagic, written LAST     */
    NowContentU16 format;       /* kNowContentFormat*                      */
    NowContentU16 reserved;     /* pairs with format; must be 0            */
    NowContentU32 length;       /* bytes valid; readers gate on >=         */

    /* --- the request. The APPLICATION writes these four; the extension
       reads them and writes nothing here. Commit order is the contract:
       arm_a5, arm_expiry and mode FIRST, arm_commit LAST; to disarm,
       clear arm_commit FIRST. A jGNE pass can land between any two
       stores, and that order is what stops a live commit word from ever
       pairing with the previous request's target. --- */
    NowContentU32 arm_a5;       /* the ONLY A5 world we will hook. 0 =
                                   named no target = we hook NOTHING.
                                   The obvious reading of a bare arm is
                                   "instrument everything"; the
                                   fail-closed reading is "instrument
                                   nothing", and a bound on count or
                                   duration is not a bound on scope
                                   (docs/resident-components.md, P3).   */
    NowContentU32 arm_expiry;   /* TickCount after which the request
                                   lapses. Bounds DURATION, not scope,
                                   and guards nothing the A5 check
                                   guards. It is here because a safety
                                   property must not depend on the
                                   caller surviving: an agent that dies
                                   mid-request must not leave hooks
                                   installed forever. 0 = expired on
                                   sight.                              */
    NowContentU32 mode;         /* kNowContentMode*                      */
    NowContentU32 arm_commit;   /* kNowContentArmCommit, written last    */

    /* --- what is actually armed. The EXTENSION writes these; the
       application reads them and writes nothing here. One writer per
       word, which is the whole locking story. --- */
    NowContentU32 active_a5;    /* 0 = nothing armed                     */
    NowContentU32 active_mode;
    NowContentU32 hooked_ports; /* rows currently in the port table      */

    /* --- the ring and its seqlock. --- */
    NowContentU32 seq;          /* odd = a record is being committed     */
    NowContentU32 ticks;        /* TickCount at last commit (liveness)   */
    NowContentU32 ring_cap;     /* == kNowContentRingCap                 */
    NowContentU32 write_cursor; /* monotonic byte count; pos = c % cap   */

    NowContentCounters counters;

    unsigned char ring[kNowContentRingCap];
} NowContentBlock;

/* ---- ring records --------------------------------------------------
   2-byte aligned, never wrapped mid-record. The reader consumes
   [reader_cursor, write_cursor) and steps by each record's own `size`,
   so `size` is the only field it must trust before anything else.

   `size` may EXCEED header + payload: when the bytes left at the ring's
   end would be too few to hold a following header, the current record
   absorbs them (now_content_logic.c). The reader steps by `size` and
   reads each payload at its own fixed width, so trailing absorbed bytes
   are skipped without a special case. This is the one place the port
   diverges from upstream's ring, and it is because upstream's ring
   never ran: its tail path could leave fewer than 12 bytes that a
   record-stepping reader would read as a header. See the test. */

#define kNowContentOpText    1
#define kNowContentOpLine    2
#define kNowContentOpRect    3
#define kNowContentOpRRect   4
#define kNowContentOpOval    5
#define kNowContentOpArc     6
#define kNowContentOpPoly    7
#define kNowContentOpRgn     8
#define kNowContentOpBits    9
#define kNowContentOpComment 10
#define kNowContentOpState   11
#define kNowContentOpWrap    255

#define kNowContentFlagTruncText 0x01  /* run longer than kNowContentTextMax */

/* STATE delta kinds. Emitted before an op when the port's live drawing
   state differs from the last one recorded for it, so the host places
   and colours ops correctly without every op carrying the state. */
#define kNowContentStateClip   1   /* a,b,c,d = clip bbox l,t,r,b         */
#define kNowContentStateOrigin 2   /* a,b = port origin h,v               */
#define kNowContentStateFg     3   /* a,b,c = rgbFgColor r,g,b            */
#define kNowContentStateBg     4   /* a,b,c = rgbBkColor r,g,b            */

typedef struct {
    NowContentU16 size;   /* whole record incl. header and any pad (even) */
    unsigned char op;     /* kNowContentOp*                               */
    unsigned char flags;  /* kNowContentFlag*                             */
    NowContentU32 port;   /* CGrafPtr - the window identity key           */
    NowContentU32 ticks;  /* TickCount at capture                         */
} NowContentRecHeader;

typedef struct {
    NowContentS16 pen_h, pen_v;  /* pen location at draw time             */
    NowContentU16 tx_font;
    NowContentU16 tx_size;
    unsigned char tx_face;
    unsigned char len;           /* inline bytes following (<= text max)  */
    NowContentU16 full_len;      /* the run's TRUE length                 */
    /* unsigned char bytes[len]; then pad to even */
} NowContentTextPayload;

typedef struct {
    NowContentS16 from_h, from_v, to_h, to_v, pn_h, pn_v;
} NowContentLinePayload;

/* RECT / RRECT / OVAL / ARC, and POLY / RGN reuse it with the bounding
   box in l..b and ext = 0 (never the point or region data). */
typedef struct {
    unsigned char verb;   /* GrafVerb: frame/paint/erase/invert/fill      */
    unsigned char pad;
    NowContentS16 l, t, r, b;
    NowContentS16 ext1, ext2;    /* oval w/h, or start/arc angle, or 0    */
} NowContentRectPayload;

/* Geometry only, NEVER pixels. The host composes a pixel island from the
   dst rect when it needs them (MirrorKit's PixelIsland). */
typedef struct {
    NowContentS16 sl, st, sr, sb;
    NowContentS16 dl, dt, dr, db;
    NowContentU16 mode;
    NowContentU16 src_row_bytes;
} NowContentBitsPayload;

typedef struct {
    unsigned char kind;   /* kNowContentState*                            */
    unsigned char pad;
    NowContentS16 a, b, c, d, e, f;
} NowContentStatePayload;

/* The offsets ARE the contract. */
_Static_assert(sizeof(NowContentRecHeader) == 12, "rec header layout");
_Static_assert(offsetof(NowContentRecHeader, port) == 4, "rec port offset");
_Static_assert(offsetof(NowContentRecHeader, ticks) == 8, "rec ticks offset");
_Static_assert(sizeof(NowContentTextPayload) == 12, "text payload layout");
_Static_assert(sizeof(NowContentLinePayload) == 12, "line payload layout");
_Static_assert(sizeof(NowContentRectPayload) == 14, "rect payload layout");
_Static_assert(sizeof(NowContentBitsPayload) == 20, "bits payload layout");
_Static_assert(sizeof(NowContentStatePayload) == 14, "state payload layout");

_Static_assert(sizeof(NowContentCounters) == 84, "counters layout");
_Static_assert(offsetof(NowContentBlock, arm_a5) == 12, "arm a5 offset");
_Static_assert(offsetof(NowContentBlock, arm_expiry) == 16, "arm expiry offset");
_Static_assert(offsetof(NowContentBlock, mode) == 20, "arm mode offset");
_Static_assert(offsetof(NowContentBlock, arm_commit) == 24, "arm commit offset");
_Static_assert(offsetof(NowContentBlock, active_a5) == 28, "active a5 offset");
_Static_assert(offsetof(NowContentBlock, seq) == 40, "seq offset");
_Static_assert(offsetof(NowContentBlock, write_cursor) == 52, "cursor offset");
_Static_assert(offsetof(NowContentBlock, counters) == 56, "counters offset");
_Static_assert(offsetof(NowContentBlock, ring) == 140, "ring offset");
_Static_assert(sizeof(NowContentBlock) == 140 + kNowContentRingCap,
               "block size");

/* ---- the arm verdict (now_content_logic.c) -------------------------
   Kept out of the Toolbox half on purpose: this is the decision that
   decides whether resident code touches another process's ports, and it
   is the one decision in the plane a host cc can execute. */
typedef struct {
    NowContentU32 plane_bits;  /* NowPeekTable.arm_request               */
    NowContentU32 arm_commit;
    NowContentU32 arm_a5;
    NowContentU32 arm_expiry;
    NowContentU32 mode;
} NowContentRequest;

enum {
    /* Nothing is asked for: plane bit clear, no commit word, or mode
       off. The plane does nothing and counts nothing. */
    kNowContentVerdictIdle = 0,
    /* Armed but named no A5 world. REFUSED - not "everything". */
    kNowContentVerdictNoTarget = 1,
    /* Deadline absent or passed. The extension retires the request
       itself, in whatever process pumps next, so retiring needs neither
       the target nor the caller to still be alive. */
    kNowContentVerdictExpired = 2,
    /* A valid request that names a DIFFERENT context than this one.
       This is the ordinary case in every process but the target, and it
       is counted so a misaddressed request shows up as traffic. */
    kNowContentVerdictOtherContext = 3,
    /* This context is the named target, within its deadline. */
    kNowContentVerdictArmed = 4
};

/* Malformed mode, bad commit word, and a zero A5 all resolve to a
   refusal rather than a permission. */
int now_content_arm_verdict(const NowContentRequest *req,
                            NowContentU32 current_a5,
                            NowContentU32 now_ticks);

/* Append one record. Returns 1 if committed, 0 if dropped (and bumps
   `dropped`). Bounded, allocation-free, and the ONLY writer of the ring
   and its seqlock. */
int now_content_ring_put(NowContentBlock *block,
                         unsigned char op, unsigned char flags,
                         NowContentU32 port,
                         const void *payload, NowContentU16 payload_len);

/* The port state the plane shadows so a STATE record is emitted only
   when something actually changed. Pure - it is fed by the Toolbox half
   and never reads a port itself. */
typedef struct {
    NowContentS16 clip_l, clip_t, clip_r, clip_b;
    NowContentS16 origin_h, origin_v;
    NowContentU16 fg_r, fg_g, fg_b;
    NowContentU16 bg_r, bg_g, bg_b;
} NowContentPortState;

enum {
    kNowContentDeltaOrigin = 1u << 0,
    kNowContentDeltaClip = 1u << 1,
    kNowContentDeltaFg = 1u << 2,
    kNowContentDeltaBg = 1u << 3
};

/* Which STATE records `live` needs relative to `shadow`. `valid` = 0
   forces all four (a port we have not recorded for yet). Does not
   mutate the shadow; the caller commits it after the records land, so a
   dropped record can never leave the shadow claiming it was sent. */
NowContentU32 now_content_state_deltas(const NowContentPortState *shadow,
                                       int valid,
                                       const NowContentPortState *live);

#endif /* NOW_CONTENT_TABLE_H */
