#include "peek_oracle.h"

#include "peek_validate.h"

/* Is this address inside the partition, treated as a BOUNDARY MARKER
   rather than as something we intend to read?

   now_peek_range_in_partition is the readability test: it answers "may I
   dereference len bytes here", and it requires addr+len <= loc+size. A
   stack base is not read - it is the high water mark of the partition,
   and on classic Mac OS the stack grows DOWN from the top of the
   application partition, so the legitimate value can be loc+size
   exactly. Running it through the readability test would reject the
   most normal case there is.

   Hence a separate, deliberately loose containment test. It rejects only
   values that are outside the partition ENTIRELY, which is the claim the
   Mismatch verdict actually makes. Anything finer - that the stack base
   should sit above A5, that it should be within some distance of the
   top - is a guess about a layout no measurement here has confirmed, and
   a wrong guess would report Mismatch for every process on the machine.
   Tightening this wants a metal observation first
   (docs/metal-and-ux-review.md). */
static int stack_base_in_partition(NowPeekU32 base, unsigned long loc,
                                   unsigned long size)
{
    unsigned long addr = (unsigned long)base;
    unsigned long top;

    if (size == 0) {
        return 0;
    }
    top = loc + size;
    if (top < loc) {
        return 0;                     /* partition end wrapped */
    }
    return addr >= loc && addr <= top;
}

/* ASCII case folding, hand-rolled and deliberately not the Toolbox's.

   Two reasons. This file must not call the Toolbox at all - that is
   what makes every verdict below reachable from a host test - and
   nothing here needs the Script Manager's idea of equality anyway: both
   names come from the same machine, one via low memory and one via the
   Process Manager, and a real difference between them is a different
   application, not a diacritic. Bytes >= 0x80 are left alone: on Mac
   Roman they fold in ways this cannot know, and folding them wrongly
   would manufacture a disagreement. */
static unsigned char fold(unsigned char c)
{
    return (c >= 'A' && c <= 'Z') ? (unsigned char)(c - 'A' + 'a') : c;
}

/* Does this slot's captured name REFUTE the process we are asking
   about? Refute, not confirm - a name is not unique (two copies of the
   same application share one), so agreement is worth nothing and only
   disagreement carries information.

   Every "cannot tell" answers 0. No name from the caller, no name in
   the slot, or a length that could not have come from the extension's
   clamp all mean the check does not run, and a check that does not run
   must never contribute to a verdict that says a process is dead.
   Comparison is case-insensitive for the reason above: a cosmetic
   difference is not evidence, and Mismatch is a strong claim. */
static int name_refutes(const unsigned char *have, const unsigned char *want)
{
    unsigned char n;
    unsigned char i;

    if (want == NULL) {
        return 0;
    }
    n = have[0];
    if (n == 0 || want[0] == 0) {
        return 0;
    }
    if (n > (unsigned char)(kNowPeekAnchorNameSize - 1)
        || want[0] > (unsigned char)(kNowPeekAnchorNameSize - 1)) {
        return 0;                     /* not a name we can trust */
    }
    if (n != want[0]) {
        return 1;
    }
    for (i = 1; i <= n; ++i) {
        if (fold(have[i]) != fold(want[i])) {
            return 1;
        }
    }
    return 0;
}

static void copy_name(unsigned char *dst, const unsigned char *src)
{
    int i;

    for (i = 0; i < (int)kNowPeekAnchorNameSize; ++i) {
        dst[i] = src[i];
    }
}

static void clear_name(unsigned char *dst)
{
    int i;

    for (i = 0; i < (int)kNowPeekAnchorNameSize; ++i) {
        dst[i] = 0;
    }
}

static void clear_match(NowPeekAnchorMatch *out)
{
    out->verdict = kNowPeekAnchorNotFound;
    out->slot = -1;
    out->stamp_ticks = 0;
    out->age_ticks = 0;
    out->a5 = 0;
    out->window_list = 0;
    out->menu_list = 0;
    out->stack_base = 0;
    clear_name(out->name);
}

NowPeekAnchorVerdict now_peek_anchor_match(const NowPeekTable *table,
                                           unsigned long loc,
                                           unsigned long size,
                                           const unsigned char *want_name,
                                           NowPeekU32 now_ticks,
                                           NowPeekU32 max_age_ticks,
                                           NowPeekAnchorMatch *out)
{
    int i;
    int qualified = 0;                /* slots passing every check */
    int rejected = 0;                 /* A5 in range, something else out */
    int has_stack = 0;                /* the format carries a 2nd root */
    int has_name = 0;                 /* the format carries a name */

    clear_match(out);
    if (table == NULL || size == 0) {
        return out->verdict;
    }
    /* A V1 table's stack_base bytes are not merely absent, they are
       whatever the shorter struct left there. Gate on the format word,
       never on the value being nonzero. The same trap, exactly, for the
       name field on a V2 table: those 32 bytes are whatever the shorter
       struct left behind, and a nonempty-looking length byte there
       would manufacture a Mismatch out of nothing. */
    has_stack = table->anchor_format >= kNowPeekAnchorFormatV2;
    has_name = table->anchor_format >= kNowPeekAnchorFormatV3;

    for (i = 0; i < (int)kNowPeekMaxAnchors; ++i) {
        const NowPeekAnchorSlot *slot = &table->anchors[i];
        NowPeekU32 s1 = slot->stamp_ticks;
        NowPeekU32 a5;
        NowPeekU32 wl;
        NowPeekU32 ml;
        NowPeekU32 sb;
        NowPeekU32 s2;
        unsigned char nm[kNowPeekAnchorNameSize];

        if (s1 == 0) {
            continue;                 /* never captured, or mid-update */
        }
        /* Seqlock: stamp, fields, stamp. The filter zeroes the stamp
           before it writes and sets it after, so an unequal pair means
           the slot changed under us and every field we just read may be
           a mix of two captures. */
        a5 = slot->a5;
        wl = slot->window_list;
        ml = slot->menu_list;
        sb = has_stack ? slot->stack_base : 0;
        /* Copied, not pointed at, and copied INSIDE the stamp pair like
           every other field: the filter can rewrite this slot between
           the two stamp reads, and a pointer into the table would let a
           caller compare against bytes that changed after we checked
           them. */
        if (has_name) {
            copy_name(nm, slot->cur_ap_name);
        } else {
            clear_name(nm);
        }
        s2 = slot->stamp_ticks;
        if (s1 != s2) {
            continue;
        }
        if (!now_peek_range_in_partition(a5, 4, loc, size)) {
            continue;                 /* not this process's A5 world */
        }
        if (has_stack && !stack_base_in_partition(sb, loc, size)) {
            /* The two roots disagree. Remembered rather than returned
               immediately: a later slot may be a clean match, and a
               clean match beside stale debris is an ordinary Ok, not a
               Mismatch. This is the whole return on carrying a second
               root - before V2 this slot was indistinguishable from the
               real one and the reader took whichever came first. */
            ++rejected;
            continue;
        }
        /* The third check, and the only one that is not about
           addresses. It sits LAST because it is the narrowest: A5 says
           whether the slot is even a candidate, the stack base bounds
           the same address space from the other end, and both can be
           satisfied by a partition that was recycled. The name cannot -
           it came out of the dead application's low memory and still
           says so.

           Counted as a rejection, not a separate outcome: the claim is
           identical to the stack base's ("a slot in this partition
           provably describes something else"), and the verdict for that
           claim already exists. What it buys is upstream of the count -
           a ghost that used to survive to the end and force Ambiguous
           now drops out here, and the live slot is the sole
           survivor. */
        if (has_name && name_refutes(nm, want_name)) {
            ++rejected;
            continue;
        }
        ++qualified;
        if (qualified > 1) {
            /* Two survivors and no tiebreaker in the table. Refuse, and
               do not leave half a match behind for a caller that
               ignores the verdict. */
            clear_match(out);
            out->verdict = kNowPeekAnchorAmbiguous;
            return out->verdict;
        }
        out->slot = (short)i;
        out->stamp_ticks = s1;
        out->a5 = a5;
        out->window_list = wl;
        out->menu_list = ml;
        out->stack_base = sb;
        copy_name(out->name, nm);
        /* Unsigned subtraction, so a TickCount that wrapped past the
           stamp still yields the true elapsed count rather than a huge
           one. TickCount wraps about every 2.2 years of uptime; the
           arithmetic is free, so there is no reason to be wrong there. */
        out->age_ticks = now_ticks - s1;
    }

    if (qualified == 1) {
        out->verdict = (max_age_ticks != 0 && out->age_ticks > max_age_ticks)
            ? kNowPeekAnchorStale
            : kNowPeekAnchorOk;
        return out->verdict;
    }
    /* Nothing survived. Mismatch and NotFound are different diagnoses -
       "a slot for this partition exists and is wrong" versus "no slot
       claims this partition at all" - and the first is the one that says
       the plane is working and the process is dead. */
    clear_match(out);
    out->verdict = rejected > 0 ? kNowPeekAnchorMismatch
                                : kNowPeekAnchorNotFound;
    return out->verdict;
}

const char *now_peek_anchor_verdict_name(NowPeekAnchorVerdict v)
{
    switch (v) {
    case kNowPeekAnchorOk:
        return "ok";
    case kNowPeekAnchorNotFound:
        return "notFound";
    case kNowPeekAnchorMismatch:
        return "mismatch";
    case kNowPeekAnchorAmbiguous:
        return "ambiguous";
    case kNowPeekAnchorStale:
        return "stale";
    }
    return "unknown";
}
