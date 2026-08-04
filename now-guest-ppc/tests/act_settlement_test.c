#include "act_settlement.h"

#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(x, why) do { if (!(x)) { fprintf(stderr, "FAIL: %s\n", why); failures++; } } while (0)

static NowActSettlementSpec window_spec(unsigned long correlation,
                                         long scene, long op)
{
    NowActSettlementSpec spec;
    memset(&spec, 0, sizeof spec);
    spec.correlation_hi = 7;
    spec.correlation_lo = correlation;
    spec.writer_epoch = 3;
    spec.target_psn_high = 0;
    spec.target_psn_low = 42;
    spec.request_scene = (NowPeekU32)scene;
    spec.kind = kNowPeekActKindWindow;
    spec.operation = kNowPeekActOpWindow;
    spec.object = 0x1234;
    spec.post_object = 0x1234;
    spec.aux = (NowPeekI32)op;
    spec.postcondition = kNowActPostWindow;
    spec.expected_a = 40;
    spec.expected_b = 50;
    return spec;
}

static void observed_window(NowScene *scene, long seq, int include,
                            short l, short t)
{
    memset(scene, 0, sizeof *scene);
    scene->seq = seq;
    scene->now_ticks = (unsigned long)(seq * 10);
    scene->proc_count = 1;
    scene->procs[0].psn.hi = 0;
    scene->procs[0].psn.lo = 42;
    if (include) {
        scene->window_count = 1;
        scene->windows[0].proc = 0;
        scene->windows[0].addr = 0x1234;
        scene->windows[0].rect.l = l;
        scene->windows[0].rect.t = t;
        scene->windows[0].rect.r = (short)(l + 100);
        scene->windows[0].rect.b = (short)(t + 80);
    }
}

static void test_late_success_and_reuse(void)
{
    NowActSettlementStore store;
    NowActSettlementSpec spec;
    NowActSettlementRecord *r;
    NowScene scene;
    int i;

    now_act_settlement_reset(&store, 3);
    spec = window_spec(1, 10, kNowPeekActWinMove);
    now_act_settlement_begin(&store, &spec, 100);
    now_act_settlement_note(&store, 7, 1, kNowActSettleTimedOut, 120);

    observed_window(&scene, 10, 1, 40, 50);
    now_act_settlement_observe_scene(&store, &scene, 3);
    r = now_act_settlement_find(&store, 7, 1);
    CHECK(r->status == kNowActSettleTimedOut,
          "the request scene cannot confirm its own action");
    observed_window(&scene, 11, 1, 40, 50);
    now_act_settlement_observe_scene(&store, &scene, 3);
    CHECK(r->status == kNowActSettleTimedOut,
          "matching pixels cannot confirm a resident action that never fired");
    now_act_settlement_note_resident(&store, 7, 1,
                                     kNowPeekActStageFired);
    observed_window(&scene, 12, 1, 40, 50);
    now_act_settlement_observe_scene(&store, &scene, 3);
    CHECK(r->status == kNowActSettleConfirmed,
          "a later normal-context scene can confirm after timeout");
    CHECK(r->timed_out_ticks == 120,
          "late success retains the fact and time of timeout");

    for (i = 2; i <= 18; i++) {
        spec = window_spec((unsigned long)i, 11, kNowPeekActWinMove);
        now_act_settlement_begin(&store, &spec, (NowPeekU32)(120 + i));
    }
    CHECK(store.count == kNowActSettlementCapacity,
          "the application store is bounded to sixteen correlations");
    CHECK(now_act_settlement_find(&store, 7, 18) != NULL,
          "act-cell reuse keeps the newest correlation independent");
    CHECK(now_act_settlement_find(&store, 7, 1) == NULL,
          "the seventeenth later record evicts the oldest only");
}

static void test_postconditions_and_session(void)
{
    NowActSettlementStore store;
    NowActSettlementSpec spec;
    NowActSettlementRecord *r;
    NowScene scene;

    now_act_settlement_reset(&store, 3);
    spec = window_spec(9, 20, kNowPeekActWinClose);
    now_act_settlement_begin(&store, &spec, 200);
    now_act_settlement_note(&store, 7, 9,
                            kNowActSettleDispatchedUnconfirmed, 201);
    now_act_settlement_note_resident(&store, 7, 9,
                                     kNowPeekActStageFired);
    observed_window(&scene, 21, 0, 0, 0);
    now_act_settlement_observe_scene(&store, &scene, 3);
    r = now_act_settlement_find(&store, 7, 9);
    CHECK(r->status == kNowActSettleConfirmed,
          "a later scene confirms the exact target window disappeared");

    spec = window_spec(11, 21, kNowPeekActWinMove);
    now_act_settlement_begin(&store, &spec, 205);
    now_act_settlement_note_resident(&store, 7, 11,
                                     kNowPeekActStageExpired);
    observed_window(&scene, 22, 1, 40, 50);
    now_act_settlement_observe_scene(&store, &scene, 3);
    r = now_act_settlement_find(&store, 7, 11);
    CHECK(r->status != kNowActSettleConfirmed,
          "expired evidence cannot confirm a pre-existing matching rect");

    spec = window_spec(10, 22, kNowPeekActWinMove);
    now_act_settlement_begin(&store, &spec, 210);
    observed_window(&scene, 23, 1, 40, 50);
    now_act_settlement_observe_scene(&store, &scene, 4);
    r = now_act_settlement_find(&store, 7, 10);
    CHECK(r->status == kNowActSettleSessionChanged,
          "writer replacement settles an open correlation honestly");
    now_act_settlement_note(&store, 7, 10,
                            kNowActSettleDispatchedUnconfirmed, 230);
    CHECK(r->status == kNowActSettleSessionChanged,
          "session-changed cannot regress to dispatched");
}

static void test_text_uses_postcondition_window(void)
{
    NowActSettlementStore store;
    NowActSettlementSpec spec;
    NowActSettlementRecord *r;
    NowScene scene;

    now_act_settlement_reset(&store, 3);
    memset(&spec, 0, sizeof spec);
    spec.correlation_hi = 7; spec.correlation_lo = 30;
    spec.writer_epoch = 3; spec.target_psn_low = 42;
    spec.request_scene = 30; spec.kind = kNowPeekActKindText;
    spec.operation = kNowPeekActOpTextSet;
    spec.object = 0xDEAD;            /* exact TEHandle operation identity */
    spec.post_object = 0x1234;       /* window identity visible in scene */
    spec.postcondition = kNowActPostText;
    spec.text_length = 2; memcpy(spec.text, "ok", 2);
    now_act_settlement_begin(&store, &spec, 300);
    now_act_settlement_note_resident(&store, 7, 30, kNowPeekActStageFired);
    observed_window(&scene, 31, 1, 0, 0);
    scene.text_count = 1; scene.windows[0].text = 0;
    strcpy(scene.texts[0].content, "ok");
    now_act_settlement_observe_scene(&store, &scene, 3);
    r = now_act_settlement_find(&store, 7, 30);
    CHECK(r->status == kNowActSettleConfirmed,
          "text settles through its window without losing TEHandle identity");
    CHECK(r->spec.object == 0xDEAD,
          "operation-specific identity remains the exact TEHandle");
}

static void test_wire_encoding_is_bounded(void)
{
    NowActSettlementStore store;
    NowActSettlementSpec spec;
    char json[4096];
    int i;
    now_act_settlement_reset(&store, 3);
    for (i = 0; i < kNowActSettlementCapacity; i++) {
        spec = window_spec((unsigned long)i + 1, 1, kNowPeekActWinMove);
        now_act_settlement_begin(&store, &spec, (NowPeekU32)(100 + i));
    }
    CHECK(now_act_settlement_encode(&store, json, sizeof json) > 0,
          "all sixteen records fit one legal control envelope");
    CHECK(strstr(json, "\"status\":\"unknown\"") != NULL,
          "the wire names unknown rather than omitting an unsettled record");
    CHECK(now_act_settlement_encode(&store, json, 32) < 0,
          "a short buffer refuses instead of truncating JSON");
}

int main(void)
{
    test_late_success_and_reuse();
    test_postconditions_and_session();
    test_text_uses_postcondition_window();
    test_wire_encoding_is_bounded();
    if (failures) return 1;
    puts("act_settlement: ok");
    return 0;
}
