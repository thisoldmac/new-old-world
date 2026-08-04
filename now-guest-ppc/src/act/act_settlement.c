#include "act_settlement.h"

#include <string.h>
#include <stdio.h>

void now_act_settlement_reset(NowActSettlementStore *s, NowPeekU32 epoch)
{
    memset(s, 0, sizeof *s);
    s->writer_epoch = epoch;
}

NowActSettlementRecord *now_act_settlement_find(NowActSettlementStore *s,
                                                 NowPeekU32 hi,
                                                 NowPeekU32 lo)
{
    int i;
    for (i = 0; i < s->count; i++) {
        NowActSettlementRecord *r = &s->records[i];
        if (r->spec.correlation_hi == hi && r->spec.correlation_lo == lo)
            return r;
    }
    return NULL;
}

NowActSettlementRecord *now_act_settlement_begin(NowActSettlementStore *s,
                                                  const NowActSettlementSpec *spec,
                                                  NowPeekU32 ticks)
{
    NowActSettlementRecord *r;
    unsigned short slot = s->next;
    if (s->count < kNowActSettlementCapacity) {
        slot = s->count++;
    }
    s->next = (unsigned short)((slot + 1) % kNowActSettlementCapacity);
    r = &s->records[slot];
    memset(r, 0, sizeof *r);
    r->spec = *spec;
    r->created_ticks = ticks;
    r->status = kNowActSettleUnknown;
    return r;
}

void now_act_settlement_note(NowActSettlementStore *s, NowPeekU32 hi,
                             NowPeekU32 lo, NowActSettlementStatus status,
                             NowPeekU32 ticks)
{
    NowActSettlementRecord *r = now_act_settlement_find(s, hi, lo);
    if (r == NULL || r->status == kNowActSettleConfirmed
        || r->status == kNowActSettleRefused
        || r->status == kNowActSettleSessionChanged
        || (r->status == kNowActSettleTimedOut
            && status != kNowActSettleTimedOut)) return;
    if (status == kNowActSettleTimedOut && r->timed_out_ticks == 0)
        r->timed_out_ticks = ticks;
    r->status = status;
    if (status == kNowActSettleRefused || status == kNowActSettleSessionChanged)
        r->terminal_ticks = ticks;
}

void now_act_settlement_note_resident(NowActSettlementStore *s,
                                      NowPeekU32 hi, NowPeekU32 lo,
                                      NowPeekU32 stage)
{
    NowActSettlementRecord *r = now_act_settlement_find(s, hi, lo);
    if (r != NULL && stage > r->resident_stage) r->resident_stage = stage;
}

static int same_psn(const NowSceneProc *p, const NowActSettlementSpec *spec)
{
    return (NowPeekU32)p->psn.hi == spec->target_psn_high
        && (NowPeekU32)p->psn.lo == spec->target_psn_low;
}

static int effect_seen(const NowActSettlementRecord *r, const NowScene *scene)
{
    const NowActSettlementSpec *spec = &r->spec;
    int i, proc = -1;

    for (i = 0; i < scene->proc_count; i++) {
        if (same_psn(&scene->procs[i], spec)) { proc = i; break; }
    }
    if (proc < 0) return 0; /* absence is not proof the app disappeared */
    if (spec->postcondition == kNowActPostFrontProcess)
        return scene->procs[proc].front != 0;

    if (spec->postcondition == kNowActPostWindow) {
        const NowSceneWindow *found = NULL;
        for (i = 0; i < scene->window_count; i++) {
            if (scene->windows[i].proc == proc
                && (NowPeekU32)scene->windows[i].addr == spec->post_object) {
                found = &scene->windows[i];
                break;
            }
        }
        if (spec->aux == kNowPeekActWinClose) return found == NULL;
        if (found == NULL) return 0;
        if (spec->aux == kNowPeekActWinSelect) return found->front != 0;
        if (spec->aux == kNowPeekActWinMove)
            return found->rect.l == spec->expected_a
                && found->rect.t == spec->expected_b;
        if (spec->aux == kNowPeekActWinResize)
            return found->rect.r - found->rect.l == spec->expected_a
                && found->rect.b - found->rect.t == spec->expected_b;
        return 0; /* zoom has no host-invented target geometry */
    }

    if (spec->postcondition == kNowActPostText) {
        for (i = 0; i < scene->window_count; i++) {
            const NowSceneWindow *w = &scene->windows[i];
            if (w->proc == proc && (NowPeekU32)w->addr == spec->post_object
                && w->text >= 0 && w->text < scene->text_count) {
                const NowSceneText *t = &scene->texts[w->text];
                size_t n = strlen(t->content);
                return !t->truncated && n == spec->text_length
                    && memcmp(t->content, spec->text, n) == 0;
            }
        }
    }
    return 0;
}

void now_act_settlement_observe_scene(NowActSettlementStore *s,
                                      const NowScene *scene,
                                      NowPeekU32 epoch)
{
    int i;
    if (s == NULL || scene == NULL) return;
    if (s->writer_epoch != 0 && epoch != s->writer_epoch) {
        for (i = 0; i < s->count; i++) {
            NowActSettlementRecord *r = &s->records[i];
            if (r->status != kNowActSettleConfirmed
                && r->status != kNowActSettleRefused) {
                r->status = kNowActSettleSessionChanged;
                r->terminal_ticks = scene->now_ticks;
            }
        }
        s->writer_epoch = epoch;
        return;
    }
    for (i = 0; i < s->count; i++) {
        NowActSettlementRecord *r = &s->records[i];
        if ((NowPeekU32)scene->seq <= r->spec.request_scene
            || r->status == kNowActSettleConfirmed
            || r->status == kNowActSettleRefused
            || r->status == kNowActSettleSessionChanged
            || r->spec.postcondition == kNowActPostNone) continue;
        /* The visual postcondition is necessary and not sufficient. A
           coincidentally matching rect/text must not confirm an action the
           resident never fired. Normal-context families publish their own
           observed dispatch stage through the same field. */
        if (r->resident_stage != kNowPeekActStageFired) continue;
        if (effect_seen(r, scene)) {
            r->status = kNowActSettleConfirmed;
            r->confirmed_scene = (NowPeekU32)scene->seq;
            r->terminal_ticks = scene->now_ticks;
        }
    }
}

void now_act_settlement_change_session(NowActSettlementStore *s,
                                       NowPeekU32 epoch, NowPeekU32 ticks)
{
    int i;
    if (s->writer_epoch == 0) { s->writer_epoch = epoch; return; }
    if (s->writer_epoch == epoch) return;
    for (i = 0; i < s->count; i++) {
        NowActSettlementRecord *r = &s->records[i];
        if (r->status != kNowActSettleConfirmed
            && r->status != kNowActSettleRefused) {
            r->status = kNowActSettleSessionChanged;
            r->terminal_ticks = ticks;
        }
    }
    s->writer_epoch = epoch;
}

const char *now_act_settlement_status_code(NowActSettlementStatus status)
{
    switch (status) {
    case kNowActSettleConfirmed: return "confirmed";
    case kNowActSettleDispatchedUnconfirmed: return "dispatched-but-unconfirmed";
    case kNowActSettleRefused: return "refused";
    case kNowActSettleTimedOut: return "timed-out";
    case kNowActSettleSessionChanged: return "session-changed";
    default: return "unknown";
    }
}

long now_act_settlement_encode(const NowActSettlementStore *s,
                               char *out, long cap)
{
    long used = 0;
    int i, n;
    if (out == NULL || cap <= 0) return -1;
    n = snprintf(out, (size_t)cap, "\"settlements\":[");
    if (n < 0 || n >= cap) return -1;
    used = n;
    for (i = 0; i < s->count; i++) {
        const NowActSettlementRecord *r = &s->records[i];
        n = snprintf(out + used, (size_t)(cap - used),
            "%s{\"correlationHi\":%lu,\"correlationLo\":%lu,"
            "\"status\":\"%s\",\"residentStage\":%lu,"
            "\"createdTicks\":%lu,\"timedOutTicks\":%lu,"
            "\"terminalTicks\":%lu,\"confirmedScene\":%lu}",
            i == 0 ? "" : ",",
            (unsigned long)r->spec.correlation_hi,
            (unsigned long)r->spec.correlation_lo,
            now_act_settlement_status_code(r->status),
            (unsigned long)r->resident_stage,
            (unsigned long)r->created_ticks,
            (unsigned long)r->timed_out_ticks,
            (unsigned long)r->terminal_ticks,
            (unsigned long)r->confirmed_scene);
        if (n < 0 || n >= cap - used) { out[0] = '\0'; return -1; }
        used += n;
    }
    n = snprintf(out + used, (size_t)(cap - used), "]");
    if (n < 0 || n >= cap - used) { out[0] = '\0'; return -1; }
    return used + n;
}
