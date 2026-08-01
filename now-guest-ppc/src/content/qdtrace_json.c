/*
 * qdtrace_json.c - the drain and the status as the wire sees them.
 *
 * Toolbox-free, because the emitter is where a short answer either
 * explains itself or does not, and that is a property worth a test.
 *
 * THE OUTPUT BUDGET IS THE REAL LIMIT ON A DRAIN. The ring budget only
 * bounds how far the cursor may travel; what actually ends a drain in
 * practice is a 4096-byte control frame filling up. So the emitter IS the
 * sink - it decides per record whether the next one fits, and answers no
 * by returning 0, which the reader turns into `more` and a cursor that
 * does not advance past the record it could not print. Separating them
 * would mean the emitter guessing how many bytes the decoder will produce,
 * and a guess that is wrong in the generous direction is a truncated JSON
 * object on the wire.
 *
 * THE FOUR WAYS A DRAIN ENDS SHORT are four different words, and this is
 * the file that has to keep them apart:
 *
 *   more    the budget ran out (bytes, records, or this buffer). Nothing
 *           was lost; call again from nextCursor.
 *   resync  the writer lapped the caller's cursor. lostBytes says how
 *           many bytes are gone. This is loss and it is reported as loss.
 *   torn    the writer lapped us DURING the read. No records are
 *           delivered; the walk is discarded rather than shipped.
 *   busy    a commit was in flight on entry. Call again.
 *
 * A caller that sees none of the four and fewer records than it hoped for
 * is looking at a machine that is not drawing - which is the answer, and
 * the only case where a short answer means what it appears to mean.
 */

#include "qdtrace.h"

#include "json.h"

#include <stdarg.h>
#include <stdio.h>
#include <string.h>

/* Room kept back for the drain's tail object. The tail is fixed-shape and
   all-numeric; 320 is roughly double its worst case, and being generous
   costs one fewer record per frame while being tight costs a malformed
   reply. */
#define kNowQDTailReserve 320L
/* The worst a single record can print: 64 text bytes that all escape to
   \uXXXX, plus the header fields and the object punctuation. */
#define kNowQDRecordReserve (kNowContentTextMax * 6 + 256)

typedef struct {
    char *out;
    long cap;
    long pos;
    long reserve;   /* tail room that must survive                     */
    int first;
} NowQDEmit;

/* Appends when the whole thing fits with `reserve` to spare, and reports
   whether it did. A partial write is never left behind: pos only moves on
   success, so an emitter that stops leaves valid JSON up to that point. */
#if defined(__GNUC__)
__attribute__((format(printf, 2, 3)))
#endif
static int emit(NowQDEmit *e, const char *fmt, ...)
{
    va_list ap;
    long room;
    int n;

    room = e->cap - e->pos - e->reserve;
    if (room <= 1) {
        return 0;
    }
    va_start(ap, fmt);
    n = vsnprintf(e->out + e->pos, (size_t)room, fmt, ap);
    va_end(ap);
    if (n < 0 || (long)n >= room) {
        e->out[e->pos] = '\0';
        return 0;
    }
    e->pos += n;
    return 1;
}

static const char *mode_name(NowContentU32 mode)
{
    switch (mode) {
    case kNowContentModeOff:    return "off";
    case kNowContentModeCount:  return "count";
    case kNowContentModeRecord: return "record";
    default:                    return "invalid";
    }
}

static const char *op_name(unsigned char op)
{
    switch (op) {
    case kNowContentOpText:    return "text";
    case kNowContentOpLine:    return "line";
    case kNowContentOpRect:    return "rect";
    case kNowContentOpRRect:   return "rrect";
    case kNowContentOpOval:    return "oval";
    case kNowContentOpArc:     return "arc";
    case kNowContentOpPoly:    return "poly";
    case kNowContentOpRgn:     return "rgn";
    case kNowContentOpBits:    return "bits";
    case kNowContentOpComment: return "comment";
    case kNowContentOpState:   return "state";
    default:                   return "unknown";
    }
}

static const char *state_kind_name(unsigned char kind)
{
    switch (kind) {
    case kNowContentStateClip:   return "clip";
    case kNowContentStateOrigin: return "origin";
    case kNowContentStateFg:     return "fg";
    case kNowContentStateBg:     return "bg";
    default:                     return "unknown";
    }
}

static const char *jbool(int v)
{
    return v ? "true" : "false";
}

void now_qdtrace_error_json(long id, const char *code, const char *message,
                            char *out, long cap)
{
    char esc[192];

    if (out == NULL || cap <= 0) {
        return;
    }
    now_json_escape(message != NULL ? message : "", esc, (long)sizeof esc);
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
             "\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}",
             id, code != NULL ? code : "error", esc);
}

/* ---- status ---------------------------------------------------------- */

void now_qdtrace_status_json(const NowQDStatus *st, long id,
                             char *out, long cap)
{
    NowQDEmit e;
    int ok;

    if (out == NULL || cap <= 0) {
        return;
    }
    out[0] = '\0';
    if (st == NULL || st->outcome == kNowQDDrainNoBlock) {
        now_qdtrace_error_json(id, "content-plane-absent",
                               "the NOW Extension publishes no content "
                               "block: not installed, or built without P3",
                               out, cap);
        return;
    }
    e.out = out;
    e.cap = cap;
    e.pos = 0;
    e.reserve = 4;
    e.first = 1;

    if (st->outcome == kNowQDDrainBadBlock) {
        char esc[192];
        char msg[192];

        snprintf(msg, sizeof msg,
                 "content block format %lu length %lu ringCap %lu is not one "
                 "this build reads",
                 (unsigned long)st->format, (unsigned long)st->length,
                 (unsigned long)st->ring_cap);
        now_json_escape(msg, esc, (long)sizeof esc);
        snprintf(out, (size_t)cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                 "\"error\":{\"code\":\"content-plane-mismatch\","
                 "\"message\":\"%s\"}}", id, esc);
        return;
    }

    /* Every emit below is && -ed into one flag rather than ignored: a
       status is a fixed shape, so a buffer that cannot hold it must
       produce a refusal and not a JSON object that stops in the middle.
       Half a reply is worse than none - it parses as far as it goes. */
    ok = emit(&e,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
        "\"output\":{\"qdtrace\":{\"cmd\":\"status\","
        "\"plane\":{\"format\":%lu,\"length\":%lu,\"ringCap\":%lu},",
        id, (unsigned long)st->format, (unsigned long)st->length,
        (unsigned long)st->ring_cap);

    /* The request and what is actually armed, side by side and never
       merged. They differ whenever a request was misaddressed, and that
       difference is the plane's most useful single diagnostic: a request
       nobody honoured looks identical to no request at all if only one
       of the two is reported. */
    ok = ok && emit(&e,
        "\"request\":{\"a5\":\"0x%08lx\",\"expiry\":%lu,\"mode\":\"%s\","
        "\"committed\":%s},",
        (unsigned long)st->arm_a5, (unsigned long)st->arm_expiry,
        mode_name(st->arm_mode), jbool(st->arm_committed));
    ok = ok && emit(&e,
        "\"active\":{\"a5\":\"0x%08lx\",\"mode\":\"%s\",\"hookedPorts\":%lu},",
        (unsigned long)st->active_a5, mode_name(st->active_mode),
        (unsigned long)st->hooked_ports);

    ok = ok && emit(&e,
        "\"ring\":{\"writeCursor\":%lu,\"seq\":%lu,\"ticks\":%lu,"
        "\"committing\":%s,\"pending\":%lu,\"lostBytes\":%lu,\"overrun\":%s},",
        (unsigned long)st->write_cursor, (unsigned long)st->seq,
        (unsigned long)st->ticks, jbool(st->committing),
        (unsigned long)st->pending, (unsigned long)st->lost_bytes,
        jbool(st->overrun));

    /* Counters, which are the whole point of a status: "is anything
       drawing at all" is answerable here without moving one record.
       Upstream shipped exactly this much and it was useful on its own. */
    ok = ok && emit(&e,
        "\"ops\":{\"total\":%lu,\"text\":%lu,\"line\":%lu,\"rect\":%lu,"
        "\"rrect\":%lu,\"oval\":%lu,\"arc\":%lu,\"poly\":%lu,\"rgn\":%lu,"
        "\"bits\":%lu,\"comment\":%lu,\"other\":%lu},",
        (unsigned long)now_qdtrace_total_ops(&st->counters),
        (unsigned long)st->counters.text, (unsigned long)st->counters.line,
        (unsigned long)st->counters.rect, (unsigned long)st->counters.rrect,
        (unsigned long)st->counters.oval, (unsigned long)st->counters.arc,
        (unsigned long)st->counters.poly, (unsigned long)st->counters.rgn,
        (unsigned long)st->counters.bits, (unsigned long)st->counters.comment,
        (unsigned long)st->counters.other);

    ok = ok && emit(&e,
        "\"loss\":{\"dropped\":%lu,\"skippedPorts\":%lu},"
        "\"lifecycle\":{\"installs\":%lu,\"uninstalls\":%lu,\"repairs\":%lu,"
        "\"arms\":%lu,\"retires\":%lu},"
        "\"refused\":{\"noTarget\":%lu,\"wrongContext\":%lu,\"expired\":%lu}",
        (unsigned long)st->counters.dropped,
        (unsigned long)st->counters.skipped_ports,
        (unsigned long)st->counters.installs,
        (unsigned long)st->counters.uninstalls,
        (unsigned long)st->counters.repairs,
        (unsigned long)st->counters.arms,
        (unsigned long)st->counters.retires,
        (unsigned long)st->counters.refused_no_target,
        (unsigned long)st->counters.refused_wrong_context,
        (unsigned long)st->counters.refused_expired);

    e.reserve = 0;
    ok = ok && emit(&e, "}}}");
    if (!ok) {
        now_qdtrace_error_json(id, "overflow",
                               "no room for a qdtrace status reply", out, cap);
    }
}

/* ---- drain ----------------------------------------------------------- */

static int drain_sink(void *ctx, const NowQDRecord *rec)
{
    NowQDEmit *e = (NowQDEmit *)ctx;
    long before = e->pos;
    const char *sep = e->first ? "" : ",";

    if (e->pos + kNowQDRecordReserve + e->reserve > e->cap) {
        return 0;   /* this buffer is full: `more`, not a silent end */
    }

    if (!emit(e, "%s{\"op\":\"%s\",\"port\":\"0x%08lx\",\"ticks\":%lu",
              sep, op_name(rec->op), (unsigned long)rec->port,
              (unsigned long)rec->ticks)) {
        e->pos = before;
        return 0;
    }
    if (!rec->payload_ok) {
        /* An op happened and its detail was unreadable - a truncated
           record, or a family a newer writer emits. Said out loud: a
           record silently reduced to a header is a drawing operation the
           host will think it saw in full. */
        if (!emit(e, ",\"detail\":false}")) {
            e->pos = before;
            return 0;
        }
        e->first = 0;
        return 1;
    }

    switch (rec->op) {
    case kNowContentOpText: {
        char esc[kNowContentTextMax * 6 + 1];

        now_json_escape((const char *)rec->text, esc, (long)sizeof esc);
        if (!emit(e,
            ",\"pen\":[%d,%d],\"font\":%u,\"size\":%u,\"face\":%u,"
            "\"len\":%u,\"fullLen\":%u,\"trunc\":%s,\"text\":\"%s\"}",
            (int)rec->p.text.pen_h, (int)rec->p.text.pen_v,
            (unsigned)rec->p.text.tx_font, (unsigned)rec->p.text.tx_size,
            (unsigned)rec->p.text.tx_face, (unsigned)rec->p.text.len,
            (unsigned)rec->p.text.full_len,
            jbool((rec->flags & kNowContentFlagTruncText) != 0), esc)) {
            e->pos = before;
            return 0;
        }
        break;
    }
    case kNowContentOpLine:
        if (!emit(e, ",\"from\":[%d,%d],\"to\":[%d,%d],\"pen\":[%d,%d]}",
                  (int)rec->p.line.from_h, (int)rec->p.line.from_v,
                  (int)rec->p.line.to_h, (int)rec->p.line.to_v,
                  (int)rec->p.line.pn_h, (int)rec->p.line.pn_v)) {
            e->pos = before;
            return 0;
        }
        break;
    case kNowContentOpRect:
    case kNowContentOpRRect:
    case kNowContentOpOval:
    case kNowContentOpArc:
    case kNowContentOpPoly:
    case kNowContentOpRgn:
        if (!emit(e, ",\"verb\":%u,\"rect\":[%d,%d,%d,%d],\"ext\":[%d,%d]}",
                  (unsigned)rec->p.rect.verb,
                  (int)rec->p.rect.l, (int)rec->p.rect.t,
                  (int)rec->p.rect.r, (int)rec->p.rect.b,
                  (int)rec->p.rect.ext1, (int)rec->p.rect.ext2)) {
            e->pos = before;
            return 0;
        }
        break;
    case kNowContentOpBits:
        /* Geometry only, never pixels - the contract's rule, and it is
           visible here as the absence of any byte field. */
        if (!emit(e,
            ",\"src\":[%d,%d,%d,%d],\"dst\":[%d,%d,%d,%d],"
            "\"mode\":%u,\"srcRowBytes\":%u}",
            (int)rec->p.bits.sl, (int)rec->p.bits.st,
            (int)rec->p.bits.sr, (int)rec->p.bits.sb,
            (int)rec->p.bits.dl, (int)rec->p.bits.dt,
            (int)rec->p.bits.dr, (int)rec->p.bits.db,
            (unsigned)rec->p.bits.mode,
            (unsigned)rec->p.bits.src_row_bytes)) {
            e->pos = before;
            return 0;
        }
        break;
    case kNowContentOpState:
        if (rec->p.state.kind == kNowContentStateClip) {
            if (!emit(e, ",\"kind\":\"clip\",\"rect\":[%d,%d,%d,%d]}",
                      (int)rec->p.state.a, (int)rec->p.state.b,
                      (int)rec->p.state.c, (int)rec->p.state.d)) {
                e->pos = before;
                return 0;
            }
        } else if (rec->p.state.kind == kNowContentStateOrigin) {
            if (!emit(e, ",\"kind\":\"origin\",\"origin\":[%d,%d]}",
                      (int)rec->p.state.a, (int)rec->p.state.b)) {
                e->pos = before;
                return 0;
            }
        } else {
            /* RGBColor components are unsigned 16-bit; a signed print
               would turn half the colour space negative. */
            if (!emit(e, ",\"kind\":\"%s\",\"rgb\":[%u,%u,%u]}",
                      state_kind_name(rec->p.state.kind),
                      (unsigned)(NowContentU16)rec->p.state.a,
                      (unsigned)(NowContentU16)rec->p.state.b,
                      (unsigned)(NowContentU16)rec->p.state.c)) {
                e->pos = before;
                return 0;
            }
        }
        break;
    default:
        if (!emit(e, ",\"detail\":false}")) {
            e->pos = before;
            return 0;
        }
        break;
    }
    e->first = 0;
    return 1;
}

void now_qdtrace_drain_json(const NowContentBlock *block,
                            NowContentU32 cursor,
                            NowContentU32 max_bytes,
                            NowContentU32 max_records,
                            long id, char *out, long cap)
{
    NowQDEmit e;
    NowQDDrainResult r;
    long head;

    if (out == NULL || cap <= 0) {
        return;
    }
    out[0] = '\0';

    e.out = out;
    e.cap = cap;
    e.pos = 0;
    e.reserve = kNowQDTailReserve;
    e.first = 1;

    if (!emit(&e,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
        "\"output\":{\"qdtrace\":{\"cmd\":\"drain\",\"ops\":[", id)) {
        now_qdtrace_error_json(id, "overflow",
                               "no room for a drain reply", out, cap);
        return;
    }
    head = e.pos;

    now_qdtrace_drain(block, cursor, max_bytes, max_records,
                      drain_sink, &e, &r);

    if (r.outcome == kNowQDDrainNoBlock) {
        now_qdtrace_error_json(id, "content-plane-absent",
                               "the NOW Extension publishes no content "
                               "block: not installed, or built without P3",
                               out, cap);
        return;
    }
    if (r.outcome == kNowQDDrainBadBlock) {
        now_qdtrace_error_json(id, "content-plane-mismatch",
                               "the content block's magic, format, length "
                               "or ring capacity is not one this build reads",
                               out, cap);
        return;
    }
    if (r.outcome == kNowQDDrainCorrupt) {
        /* A record size the ring cannot contain. Not reported as an empty
           drain: the caller must know the ring is unreadable, because the
           remedy is to stop and re-arm, not to poll again. */
        now_qdtrace_error_json(id, "content-ring-corrupt",
                               "a ring record's size is not one a record "
                               "can have; the ring cannot be walked",
                               out, cap);
        return;
    }

    /* A torn or busy read delivered nothing, so anything the sink managed
       to print before the tear is retracted here rather than shipped. */
    if (r.outcome == kNowQDDrainTorn || r.outcome == kNowQDDrainBusy) {
        e.pos = head;
        e.out[e.pos] = '\0';
        e.first = 1;
    }

    /* The tail always fits: every emit above held kNowQDTailReserve back,
       and the tail is smaller than it. Checked anyway, because the day
       that stops being true is the day the reply goes out truncated and
       parses as far as it goes. */
    e.reserve = 0;
    if (!emit(&e,
        "],\"cursor\":%lu,\"nextCursor\":%lu,\"writeCursor\":%lu,"
        "\"pending\":%lu,\"records\":%lu,\"wraps\":%lu,"
        "\"more\":%s,\"resync\":%s,\"torn\":%s,\"busy\":%s,"
        "\"lostBytes\":%lu,\"dropped\":%lu}}}",
        (unsigned long)r.cursor, (unsigned long)r.next_cursor,
        (unsigned long)r.write_cursor, (unsigned long)r.pending,
        (unsigned long)r.records, (unsigned long)r.wraps,
        jbool(r.more), jbool(r.resync),
        jbool(r.outcome == kNowQDDrainTorn),
        jbool(r.outcome == kNowQDDrainBusy),
        (unsigned long)r.lost_bytes, (unsigned long)r.dropped)) {
        now_qdtrace_error_json(id, "overflow",
                               "no room for a qdtrace drain reply", out, cap);
    }
}
