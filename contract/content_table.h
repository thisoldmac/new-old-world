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

/* THE TWO ADDITIONS TO peek_table.h THIS PLANE NEEDED landed 2026-07-31,
   and the shim that stood in for the first is gone - it did retire
   itself on the `#define NOW_PEEK_TABLE_HAS_CAP_CONTENT`, and is deleted
   here rather than left standing, because a stand-in nobody compiles is
   a definition nobody checks.

   NEITHER LANDED AT THE NUMBER THIS FILE ASKED FOR, and the correction is
   worth stating rather than quietly absorbing. This header asked for
   `1u << 2` and for the appended field at 36 + 60 * kNowPeekMaxAnchors.
   The act plane (P4) had taken both while this one was being written -
   two lanes each picking the next free bit and the next free offset from
   the version of the header they could see. So P3 is `1u << 3`, and
   content_block is appended after P4's cell.

   The offset collision would have been loud: an offsetof assert fails at
   compile time. The BIT collision would have been silent and much worse
   - an application arming the content plane would have armed P4's six
   trap patches instead, inside another process. That is the reason
   peek_table.h states every bit and offset in one place, and the reason
   both numbers are asserted there rather than described here.

   What the field is for is unchanged: it is how the application FINDS
   this block. The extension allocates it in the system heap and
   publishes its address there, 0 meaning absent. Appended, so accretive
   under the header's own prefs-record rule - a reader that predates it
   gates on `length` and never looks, and no existing offset moved. */

enum {
    /* 'NWcb' - the block's own magic, distinct from the table's. */
    kNowContentBlockMagic = (long)NOW_PEEK_4CC('N', 'W', 'c', 'b'),

    /* Plane format word. A reader requires an exact match AND
       length >= what it reads, the accretive prefs-record rule. */
    kNowContentFormatNone = 0,
    kNowContentFormatV1 = 1,
    kNowContentFormatV2 = 2,

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
    kNowContentModeRecord = 2,  /* count + append ring records */
    /* THE GWORLD PROBE (docs/gworld-probe-brief.md): record mode, plus
       the plane follows a window blit back to the offscreen GWorld that
       sourced it and hooks THAT port too, so the drawing that BUILT the
       composite is recorded under the GWorld's own port key. An
       experiment, not a shipping mode: it is armed the same way, scoped
       to the same one process, and everything it hooks beyond the scene
       window is counted in the probe_* fields below. An extension that
       predates this value reads it as unrecognised and stays idle -
       fail closed, per the rule above. */
    kNowContentModeProbe = 3
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

    /* --- v2 exact-window request and correlation --------------------
       Appended: every v1 offset above remains fixed. The PSN is echoed
       correlation, never resident safety authority. Only arm_a5 plus an
       exact current WindowList membership permits a port dereference. */
    NowContentU32 arm_window;
    NowContentU32 arm_psn_hi;
    NowContentU32 arm_psn_lo;
    NowContentU32 arm_generation;

    NowContentU32 active_window;
    NowContentU32 active_psn_hi;
    NowContentU32 active_psn_lo;
    NowContentU32 active_generation;
    NowContentU32 display_epoch;

    /* Requested means InvalWindowRect was issued in the exact owning
       context. Serviced means a later QuickDraw hook was observed; an
       invalidation alone is never reported as a serviced redraw. */
    NowContentU32 redraw_requested_generation;
    NowContentU32 redraw_serviced_generation;
    NowContentU32 redraw_requests;
    NowContentU32 redraw_services;

    /* --- the GWorld probe (kNowContentModeProbe), appended ----------
       Accretive under the same rule as v2: every offset above is fixed
       and a reader gates on `length` before looking here.

       The pending cell is how the draw-time half talks to the GNE-moment
       half WITHIN the armed process: a bits hook that sees a window blit
       whose source is a PixMap it has not met stashes that PixMap
       pointer here, and the next jGNE pass in the same context - the
       only moment the Toolbox is safe - goes looking for the CGrafPort
       that owns it and hooks it. One cell, deliberately: a second
       sighting before service re-offers itself on a later blit. */
    NowContentU32 probe_pending_pixmap;  /* PixMap* from a blit, 0 = none */
    NowContentS16 probe_pending_l, probe_pending_t;  /* its bounds, for  */
    NowContentS16 probe_pending_r, probe_pending_b;  /* the port match   */
    /* The second join key, measured necessary on the OS 9 Finder: its
       composite blit's source PixMap does NOT RecoverHandle (a stack or
       nonrelocatable PixMap record aimed at the GWorld's pixels is a
       normal CopyBits idiom), so the chase also matches a candidate
       port by what its own portPixMap points AT - same baseAddr, same
       rowBytes, same bounds. */
    NowContentU32 probe_pending_base;    /* the sighted PixMap's baseAddr */
    NowContentU16 probe_pending_row_bytes; /* raw, flags included         */
    NowContentU16 probe_pending_pad;

    NowContentU32 probe_pixmaps_seen;    /* distinct source pixmaps sighted */
    NowContentU32 probe_scans;           /* zone scans actually run         */
    NowContentU32 probe_hits;            /* offscreen ports found + hooked  */
    NowContentU32 probe_misses;          /* sightings that led to no port   */
    NowContentU32 probe_offscreen_ports; /* offscreen rows currently held   */
    NowContentU32 probe_stale_rows;      /* offscreen rows dropped after
                                            their port stopped matching -
                                            a disposed GWorld, counted
                                            rather than dereferenced      */
    /* Diagnosis fields, because the first Finder run produced a counter
       pattern (scan ran, neither hit nor miss) whose one consistent
       explanation was surprising enough to demand the address rather
       than the inference. last_match is the candidate the scan matched,
       whoever it was; already_ours counts matches that were in the
       table before the scan looked. */
    NowContentU32 probe_last_match;
    NowContentU32 probe_already_ours;
    /* THE DECISIVE COUNT, and it deliberately asks a WEAKER question
       than the match does: how many CGrafPort-shaped blocks anywhere in
       either heap have a pixmap pointing at the sighted pixels, rect
       agreement not required. Zero means no port owns those pixels and
       the semantic road is closed by mechanism rather than by a strict
       comparison; nonzero means a port exists and the match was too
       strict, which is a bug in the instrument and not an answer about
       the application. Without this the two are indistinguishable. */
    NowContentU32 probe_base_candidates;
    NowContentU32 probe_first_candidate;
    NowContentS16 probe_cand_l, probe_cand_t;   /* its portRect, so a  */
    NowContentS16 probe_cand_r, probe_cand_b;   /* near-miss is legible */
    /* WHAT THE SIGHTING SAW, which is a different question from what the
       search found and was indistinguishable from it until now. A
       control run that chased seven pixmaps and found none of them is a
       broken search; a control run that never sighted the blit it was
       aimed at tested nothing at all. These four separate the two. */
    NowContentU32 probe_sight_offers;  /* qualifying blits sighted       */
    NowContentU32 probe_sight_busy;    /* dropped: a chase was pending   */
    NowContentU32 probe_sight_seen;    /* dropped: already chased once   */
    NowContentU32 probe_last_sight;    /* the most recent offer's PixMap */
    NowContentS16 probe_sight_l, probe_sight_t;
    NowContentS16 probe_sight_r, probe_sight_b;
    /* Blits too small to be a composite, refused before they can take
       the chase slot. Measured 2026-08-06: 122 of 148 offers were
       dropped as busy because a scroll arrow claimed the slot ahead of
       the content-sized blit we are actually hunting. */
    NowContentU32 probe_sight_small;
    /* THE HANDLE, recovered at SIGHT time. A PixMap record is a
       relocatable block, so the pointer a blit hands us is valid only
       until the next thing that moves memory - and the chase runs one
       event-loop pass later. Recovering the handle while the pointer is
       still live carries an identity across that gap instead of a
       snapshot. 0 = the source did not recover (a stack or
       nonrelocatable PixMap, which is a legitimate CopyBits idiom). */
    NowContentU32 probe_pending_handle;

    /* --- the QDExtensions trap patch (plan 014, E1), appended --------
       Accretive under the same rule as everything above it: a reader
       gates on `length` before looking, and no offset moved.

       WHAT THESE ANSWER, and it is one question the whole approach
       rests on: does a 68K patch on $AB1D see a CFM caller's
       NewGWorld? The sight-then-chase discovery cannot reach a world
       that is created, drawn and disposed inside one event-loop pass
       (Sherlock 2: 7 composites offered, 0 hooked), so creation-time
       notification is the only route to those interiors - and it
       exists only if these counters move.

       `qdext_calls` counts every dispatch through the patch in the
       ARMED context; `qdext_new_gworld` counts selector 0 alone,
       because the raw count is dominated by ambient traffic (measured
       ~0.6 selector-7 calls a second in an idle process, which drowns
       a single NewGWorld). `qdext_last_selector` is the whole d0 -
       paramBytes in the high word, selector in the low - so a
       surprising number is legible rather than merely wrong.
       `qdext_foreign` counts dispatches seen in a context that is NOT
       the armed one: nonzero means the patch is live machine-wide,
       which is a scope fact worth seeing rather than inferring. */
    NowContentU32 qdext_calls;
    NowContentU32 qdext_new_gworld;
    NowContentU32 qdext_last_selector;
    NowContentU32 qdext_foreign;
    /* 0 = never installed, else the incumbent we chain to. Reported so
       a patch that failed to install is distinguishable from one that
       installed and never fired - the two look identical in counters
       alone, and that ambiguity voided the applet experiment. */
    NowContentU32 qdext_installed;
    /* E2's own arithmetic: worlds hooked at birth, worlds dropped at
       death, and births the port table could not take (full, or a port
       carrying the application's own grafProcs). A widget-per-world
       application can exhaust 16 rows in one pass, so the missed count
       is the honesty counter that says so. */
    NowContentU32 qdext_born;
    NowContentU32 qdext_died;
    NowContentU32 qdext_born_missed;

    /* --- the arm-time census (plan 018), appended -------------------
       Accretive under the same rule as everything above it: a reader
       gates on `length` before looking, and no offset moved.

       WHAT THIS EXISTS FOR. The trap patch above hooks a world at the
       instant it is BORN, which reaches every world created after the
       plane was armed and no world created before it. A Finder window
       that was already open when recording started therefore composites
       into a world nothing names: its blit arrives with an unjoinable
       source, the ladder correctly refuses to guess, and the interior
       renders as one honest hatch. That is the largest visible defect
       the 2026-08-07 fidelity sweep found, and it is capture-side.

       The census closes it by enumerating the worlds that already
       exist, once, at arm time, in the armed process's own heap - and
       hooking each one through exactly the path a birth takes, so a
       censused world and a born world are indistinguishable downstream.
       It emits the same `worldBorn` record; the host's join needs no
       new vocabulary and the contract gains no message.

       WHY THESE COUNTERS AND NOT A BOOLEAN. A census that finds nothing
       and a census that never ran look identical from outside, and this
       project has paid for that ambiguity twice (`qdext_installed`
       exists for the same reason). `runs` says it happened; `bytes` and
       `usecs` are the COST, measured on the machine rather than
       estimated; `examined` is how many blocks got past the cheap
       filter into a dereference; `found` how many passed the match;
       `hooked` how many became rows. The four subtractions between them
       are each a different verdict, and each was worth a separate
       number the first time it was nonzero.

       `truncated` is the honest-degradation flag: a heap larger than
       the byte budget is swept as far as the budget reaches and SAYS
       so, rather than either stalling a cooperatively-scheduled machine
       or pretending completeness. */
    NowContentU32 census_runs;         /* censuses actually started       */
    NowContentU32 census_bytes;        /* heap span swept, bytes          */
    NowContentU32 census_usecs;        /* wall cost of the last sweep     */
    NowContentU32 census_examined;     /* candidates that got a deref     */
    NowContentU32 census_found;        /* candidates that matched a world */
    NowContentU32 census_hooked;       /* worlds that became rows         */
    NowContentU32 census_windows;      /* matched, but on the WindowList  */
    NowContentU32 census_already;      /* matched, already a row          */
    NowContentU32 census_unrecoverable;/* matched, but not a live handle  */
    NowContentU32 census_refused;      /* rows the port table could not take,
                                          plus censuses that never ran at
                                          all (no zone, or a zone whose own
                                          bounds cannot be believed)      */
    NowContentU32 census_truncated;    /* sweeps cut short by the budget  */
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
   never ran: its tail path could leave fewer than a complete header that a
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
/* Emitted in probe mode only, immediately BEFORE the bits record whose
   source it names (plan 013, slice A, option 2): a separate record
   rather than a wider bits payload, because a ring reader steps records
   by their own `size` and reads each payload at a fixed width - a
   longer NowContentBitsPayload written by a new resident and read by an
   old host is a misparse, while an unknown op is stepped over whole and
   the old reader loses only the join it never had. */
#define kNowContentOpBlitSource 12
/* A world's birth and death, emitted by the QDExtensions trap patch
   (plan 014, E2) in the creating process at the instant NewGWorld
   returns and DisposeGWorld is entered. Accretive like blitsrc: an
   older reader steps over both whole. worldDied is what lets a host
   release held ops on the application's own word rather than on a
   retention guess. */
#define kNowContentOpWorldBorn  13
#define kNowContentOpWorldDied  14
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
    NowContentU32 a5;     /* exact resident safety target                 */
    NowContentU32 psn_hi; /* echoed correlation, not resident authority  */
    NowContentU32 psn_lo;
    NowContentU32 display_epoch;
    NowContentU32 generation;
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
   box in l..b (never the point or region data).

   THE SHAPE DISCRIMINATOR (2026-08-06). RGN and POLY used to send ext = 0
   as well, and that made the host's bounding box UNFALSIFIABLE: it drew
   every region as a hard rectangle and had no way to say whether that was
   the shape or an approximation of it. The measured corpus is 39 region
   ops across nine live captures, every one an erase, and nothing in the
   data could distinguish a rectangular update region from an L-shaped one
   - which is itself the argument for sending a discriminator rather than
   the shape.

   Sending the SHAPE was considered and refused. A region is unbounded in
   size, the ring is the measured limit (a hooked Sherlock overran 64 KiB
   in one settle), and the overwhelmingly common region is rectangular, so
   the expensive answer would be paid on every op to serve the rare one.
   The cheap discriminator costs nothing at all: it rides in a field the
   payload already carries and already zeroes, so no record grew, the ring
   budget is unchanged, and an older host reads ext1 = 0 exactly as it did
   before.

     RGN  - ext1 = the region's own rgnSize in bytes, ext2 = 0.
             QuickDraw stores a rectangular region as the minimum 10-byte
             Region record, so ext1 == 10 means "the bounding box IS the
             whole shape" and the host's rectangle is exact. ext1 > 10
             means the box is an approximation and the host must say so
             rather than draw a confident rectangle.
     POLY - ext1 = the polygon's own polySize in bytes, ext2 = 0. A
             polygon is NEVER its bounding box (polySize > 10 always), so
             this is honesty telemetry rather than a fast path; it is set
             for symmetry and because the size names how much shape the
             box is hiding.

   ext1 == 0 is therefore a THIRD state and not a synonym for either: it
   is a resident that predates this rule, and a host must report "shape
   unreported" rather than assume rectangular. That distinction is the
   whole value of the field - a zero pretending to be an answer is the
   failure this contract keeps refusing elsewhere. */
typedef struct {
    unsigned char verb;   /* GrafVerb: frame/paint/erase/invert/fill      */
    unsigned char pad;
    NowContentS16 l, t, r, b;
    /* oval w/h, or start/arc angle, or rgnSize/polySize, or 0            */
    NowContentS16 ext1, ext2;
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

/* The join the host could never make (plan 013): the bits payload
   deliberately carries no source identity, so ops recorded under an
   offscreen port's key and the blit that reveals them in a window were
   two piles nothing connected. This record precedes that blit and names
   the source. `src_port` is the offscreen CGrafPtr this plane HOOKED -
   resolved at the instant the blit runs by dereferencing each offscreen
   row's stored PixMapHandle and comparing against the blit's own source
   pointer, both read in the same moment so LockPixels relocation cannot
   separate them (013 A2.1). `src_pixmap` is that row's handle, for
   diagnosis. Absence of this record before a bits op is the existing
   behaviour: an unhooked source, a hand-built PixMap, or an older
   resident - never a zero pretending to be an answer. */
typedef struct {
    NowContentU32 src_port;
    NowContentU32 src_pixmap;
} NowContentBlitSourcePayload;

/* WORLDBORN carries the world's identity and shape; WORLDDIED carries
   the port alone and zeroes the rest, because after disposal there is
   nothing left to read and a shape copied from a freed block would be
   a plausible lie. */
typedef struct {
    NowContentU32 port;
    NowContentU32 pixmap;
    NowContentS16 l, t, r, b;
} NowContentWorldPayload;

/* The offsets ARE the contract. */
_Static_assert(sizeof(NowContentRecHeader) == 32, "rec header layout");
_Static_assert(offsetof(NowContentRecHeader, port) == 4, "rec port offset");
_Static_assert(offsetof(NowContentRecHeader, ticks) == 8, "rec ticks offset");
_Static_assert(offsetof(NowContentRecHeader, generation) == 28,
               "rec generation offset");
_Static_assert(sizeof(NowContentTextPayload) == 12, "text payload layout");
_Static_assert(sizeof(NowContentLinePayload) == 12, "line payload layout");
_Static_assert(sizeof(NowContentRectPayload) == 14, "rect payload layout");
_Static_assert(sizeof(NowContentBitsPayload) == 20, "bits payload layout");
_Static_assert(sizeof(NowContentStatePayload) == 14, "state payload layout");
_Static_assert(sizeof(NowContentBlitSourcePayload) == 8,
               "blit source payload layout");
_Static_assert(sizeof(NowContentWorldPayload) == 16,
               "world payload layout");

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
_Static_assert(offsetof(NowContentBlock, arm_window)
                   == 140 + kNowContentRingCap,
               "v2 append offset");
_Static_assert(offsetof(NowContentBlock, probe_pending_pixmap)
                   == 192 + kNowContentRingCap,
               "probe append offset");
_Static_assert(offsetof(NowContentBlock, qdext_calls)
                   == 292 + kNowContentRingCap,
               "qdext append offset");
_Static_assert(offsetof(NowContentBlock, census_runs)
                   == 324 + kNowContentRingCap,
               "census append offset");
_Static_assert(sizeof(NowContentBlock) == 368 + kNowContentRingCap,
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
    NowContentU32 arm_window;
    NowContentU32 arm_psn_hi;
    NowContentU32 arm_psn_lo;
    NowContentU32 arm_generation;
} NowContentRequest;

/* Pure owning-context lifecycle decision. A stored port may be inspected
   only after `window_live` was established by exact WindowList membership;
   `hook_owned` is meaningful only when window_live is true. */
typedef struct {
    int verdict;
    NowContentU32 current_a5;
    NowContentU32 request_window;
    NowContentU32 request_generation;
    NowContentU32 slot_a5;
    NowContentU32 slot_window;
    NowContentU32 slot_generation;
    int has_slot;
    int window_live;
    int hook_owned;
    int redraw_requested;
} NowContentLifecycleFacts;

enum {
    kNowContentLifeInstall = 1u << 0,
    kNowContentLifeRestore = 1u << 1,
    kNowContentLifeForget = 1u << 2,
    kNowContentLifeInvalidate = 1u << 3,
    kNowContentLifeRetire = 1u << 4
};

NowContentU32 now_content_lifecycle_decide(
    const NowContentLifecycleFacts *facts);

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

/* ---- the probe's port match (now_content_logic.c) ------------------
   The one decision in the GWorld probe a host cc can execute: given the
   fields read at a candidate heap address, is it the offscreen CGrafPort
   that owns the blit's source pixmap? Three tests, all required:
     - portPixMap holds exactly the handle RecoverHandle returned for
       the sighted PixMap (identity, not shape);
     - portVersion carries Color QuickDraw's 0xC000 discriminator, the
       same test now_content.c applies before ever touching grafProcs;
     - portRect equals the pixmap's bounds, which NewGWorld guarantees
       for a GWorld and nothing guarantees for a stray pointer that
       happens to alias the handle value.
   Pure by construction so the false-positive reasoning is testable: the
   caller extracts the scalars, this decides. */
int now_content_probe_match(NowContentU32 cand_pixmap_handle,
                            NowContentU16 cand_port_version,
                            NowContentS16 cand_l, NowContentS16 cand_t,
                            NowContentS16 cand_r, NowContentS16 cand_b,
                            NowContentU32 want_pixmap_handle,
                            NowContentS16 want_l, NowContentS16 want_t,
                            NowContentS16 want_r, NowContentS16 want_b);

/* The deref route: the same verdict when the sighted PixMap could not
   RecoverHandle. The caller has already dereferenced the candidate's
   own portPixMap; this compares what it points AT with what the blit
   named. rowBytes is compared with its flag bits masked (0x3FFF): the
   sighted record carries a PixMap's flags, and the GWorld's own record
   carries them too, but nothing guarantees the two idioms set the same
   high bits over the same pixels. */
int now_content_probe_pixmap_match(NowContentU16 cand_port_version,
                                   NowContentS16 cand_l, NowContentS16 cand_t,
                                   NowContentS16 cand_r, NowContentS16 cand_b,
                                   NowContentU32 cand_base,
                                   NowContentU16 cand_row_bytes,
                                   NowContentS16 pm_l, NowContentS16 pm_t,
                                   NowContentS16 pm_r, NowContentS16 pm_b,
                                   NowContentU32 want_base,
                                   NowContentU16 want_row_bytes,
                                   NowContentS16 want_l, NowContentS16 want_t,
                                   NowContentS16 want_r, NowContentS16 want_b);

/* ---- the arm-time census's verdict (now_content_logic.c) ------------
   Given one block of the armed process's heap read as a CGrafPort, plus
   what its portPixMap points AT: is this a live offscreen graphics
   world? The caller does the reading and the range checking; this only
   decides, so the decision is testable on the host cc where a wrong
   answer costs nothing.

   IT ASKS ONLY QUESTIONS THAT SURVIVE HEAP MOTION, and that is the
   design rather than an accident. `LockPixels` relocates the PixMap
   RECORD (docs/toolbox-and-gworld.md §6), so a baseAddr or a recovered
   handle taken at one moment is not the same number at the next. Every
   test below is either a discriminator bit or a SHAPE - bounds and
   rowBytes - and shape is what a relocation leaves alone. `pm_base` is
   read only for the nonzero test: a zeroed block is not a world, and
   half a heap is zeroed blocks.

   THE ONE THAT DOES THE WORK is `portRect == pixmap bounds`. It is the
   GWorld invariant - `NewGWorld` sets both from the same rectangle -
   and it is also what excludes every WINDOW port in the machine
   without a list walk: a window's portRect is local while its
   portPixMap is the SCREEN's, whose bounds are global and the size of
   the display. The caller still checks WindowList membership before
   hooking, because a full-screen window at the origin is the one case
   where the two rectangles could agree. */
int now_content_census_match(NowContentU16 port_version,
                             NowContentU32 port_pixmap_handle,
                             NowContentS16 port_l, NowContentS16 port_t,
                             NowContentS16 port_r, NowContentS16 port_b,
                             NowContentU32 pm_base,
                             NowContentU16 pm_row_bytes,
                             NowContentS16 pm_l, NowContentS16 pm_t,
                             NowContentS16 pm_r, NowContentS16 pm_b);

/* ---- the blit's source port (now_content_logic.c) ------------------
   The decision behind the blit-source record: given the port table's
   offscreen rows with each row's PixMapHandle DEREFERENCED at this same
   instant, and the source PixMap the bits hook was handed, which hooked
   port owns the composite? The deref-now rule is 013 A2.1: a stored
   deref is a snapshot of a block LockPixels has moved, so the caller
   reads *(PixMapHandle)row.pixmap in the same moment it compares.

   TWO ROUTES, because pointer identity alone measured FALSE on the
   control (2026-08-06): the record the bits bottleneck receives is not
   the GWorld's own PixMap record - the control's blit of *pix arrived
   as a copy at an ODD address (0x1eb6aaae) while the live deref was
   elsewhere - so `pixmap_deref == src_bits` never fired. This is the
   same fact that forced the chase's deref route, one hook further in.
   Identity is kept as the cheap exact first test; SHAPE - the same
   now_content_probe_pixmap_match the chase trusts - is the route that
   actually matches, and it needs the row's port and pixmap geometry
   read at the same instant as the deref. */
typedef struct {
    NowContentU32 port;         /* gPorts[i].port                        */
    NowContentU32 a5;           /* gPorts[i].a5                          */
    int offscreen;              /* gPorts[i].offscreen                   */
    NowContentU32 pixmap;       /* gPorts[i].pixmap - the handle         */
    NowContentU32 pixmap_deref; /* *(PixMapHandle)pixmap, read NOW       */
    /* Shape, all read through that same deref in the same moment. */
    NowContentU16 port_version; /* the port's own discriminator          */
    NowContentS16 rect_l, rect_t, rect_r, rect_b;   /* port->portRect    */
    NowContentU32 base;         /* pm->baseAddr                          */
    NowContentU16 row_bytes;    /* pm->rowBytes, raw with flags          */
    NowContentS16 pm_l, pm_t, pm_r, pm_b;           /* pm->bounds        */
} NowContentBlitSourceRow;

/* Returns the owning row's port, or 0: no match, an ambiguous match,
   or a NULL/zero source. Zero is the record NOT being emitted. The
   src_* fields are the sighted record's own, read from the pointer the
   hook was handed while it is live. */
NowContentU32 now_content_blit_source(const NowContentBlitSourceRow *rows,
                                      int count,
                                      NowContentU32 armed_a5,
                                      NowContentU32 src_bits,
                                      NowContentU32 src_base,
                                      NowContentU16 src_row_bytes,
                                      NowContentS16 src_l,
                                      NowContentS16 src_t,
                                      NowContentS16 src_r,
                                      NowContentS16 src_b);

#endif /* NOW_CONTENT_TABLE_H */
