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

/* THE MENU MARK POSTCONDITION.
 *
 * Before it existed, every menu act carried kNowActPostNone and could
 * therefore never leave `dispatched-but-unconfirmed`. Watched on an
 * emulator clone 2026-08-07: the Finder's `as Buttons` switched the
 * window, and the reply said unconfirmed with the proof - the checkmark
 * on menu 259 item 2 - sitting in the very next scene. */
static void menubar_scene(NowScene *scene, long seq, short menu_id,
                          short marked_item, int menubar_proc)
{
    memset(scene, 0, sizeof *scene);
    scene->seq = seq;
    scene->now_ticks = (unsigned long)(seq * 10);
    scene->proc_count = 1;
    scene->procs[0].psn.hi = 0;
    scene->procs[0].psn.lo = 42;
    scene->menubar_present = 1;
    scene->menubar_proc = (short)menubar_proc;
    scene->menu_count = 1;
    scene->menus[0].id = menu_id;
    scene->menus[0].items_present = 1;
    scene->menus[0].first_item = 0;
    scene->menus[0].item_count = 3;
    scene->menu_item_count = 3;
    scene->menu_items[0].index = 1;
    scene->menu_items[1].index = 2;
    scene->menu_items[2].index = 3;
    scene->menu_items[marked_item - 1].mark = 1;
}

static NowActSettlementSpec menu_spec(unsigned long correlation, long scene,
                                       short menu_id, short item)
{
    NowActSettlementSpec spec;
    memset(&spec, 0, sizeof spec);
    spec.correlation_hi = 7;
    spec.correlation_lo = correlation;
    spec.writer_epoch = 3;
    spec.target_psn_low = 42;
    spec.request_scene = (NowPeekU32)scene;
    spec.kind = kNowPeekActKindMenu;
    spec.operation = kNowPeekActOpMenu;
    spec.postcondition = kNowActPostMenuMark;
    spec.post_object = (NowPeekU32)menu_id;
    spec.expected_a = item;
    return spec;
}

static void test_menu_mark_postcondition(void)
{
    NowActSettlementStore store;
    NowActSettlementSpec spec;
    NowActSettlementRecord *r;
    NowScene scene;

    now_act_settlement_reset(&store, 3);
    spec = menu_spec(1, 10, 259, 2);
    r = now_act_settlement_begin(&store, &spec, 100);
    now_act_settlement_note_resident(&store, 7, 1, kNowPeekActStageFired);

    /* The mark still on the item that had it: the press has not landed. */
    menubar_scene(&scene, 11, 259, 1, 0);
    now_act_settlement_observe_scene(&store, &scene, 3);
    CHECK(r->status != kNowActSettleConfirmed,
          "a mark still on the OLD item does not confirm the press");

    /* Another application owns the menu bar. One bar per machine, so a
       menu with this id under a different process is a different menu. */
    menubar_scene(&scene, 12, 259, 2, 1);
    now_act_settlement_observe_scene(&store, &scene, 3);
    CHECK(r->status != kNowActSettleConfirmed,
          "a mark in ANOTHER process's menu bar cannot confirm this act");

    menubar_scene(&scene, 13, 259, 2, 0);
    now_act_settlement_observe_scene(&store, &scene, 3);
    CHECK(r->status == kNowActSettleConfirmed,
          "the mark landing on the item pressed confirms the menu act");
    CHECK(r->confirmed_scene == 13, "and names the scene that settled it");
}

static void test_menu_mark_needs_the_resident_to_have_fired(void)
{
    NowActSettlementStore store;
    NowActSettlementSpec spec;
    NowActSettlementRecord *r;
    NowScene scene;

    /* The visual postcondition is necessary and not sufficient, exactly
       as for a window act: a menu whose mark already sat where we want it
       must not confirm an act the resident never fired. */
    now_act_settlement_reset(&store, 3);
    spec = menu_spec(2, 10, 259, 2);
    r = now_act_settlement_begin(&store, &spec, 100);
    menubar_scene(&scene, 11, 259, 2, 0);
    now_act_settlement_observe_scene(&store, &scene, 3);
    CHECK(r->status != kNowActSettleConfirmed,
          "a matching mark alone never confirms an act that did not fire");
}

/* An act with NO scene postcondition can still be settled, because the
   application looked.
   ---------------------------------------------------------------------
   A control act carries kNowActPostNone: nothing in a scene names the
   control it aimed at, so now_act_settlement_observe_scene skips it
   forever and its resident stage never reaches Fired when no patch was
   asked to answer. Before now_act_note_observed() that meant a `ctlact`
   could ONLY ever read `dispatched-but-unconfirmed` or `timed-out` - and
   on 2026-08-07 it read `timed-out` on a press confirmed in the guest's
   own pixels.

   act_settlement.h has always allowed the other route ("or an explicit
   application observation"). This is the gate that it works, and that a
   scene pass afterwards cannot undo it. */
static void test_an_application_observation_settles_a_control_act(void)
{
    NowActSettlementStore store;
    NowActSettlementSpec spec;
    NowActSettlementRecord *r;
    NowScene scene;

    now_act_settlement_reset(&store, 3);
    memset(&spec, 0, sizeof spec);
    spec.correlation_hi = 7;
    spec.correlation_lo = 1;
    spec.writer_epoch = 3;
    spec.target_psn_low = 42;
    spec.request_scene = 10;
    spec.kind = kNowPeekActKindControl;
    spec.operation = kNowPeekActOpControl;
    spec.object = 0xC0DE;
    spec.postcondition = kNowActPostNone;      /* no scene can name it */

    r = now_act_settlement_begin(&store, &spec, 100);
    now_act_settlement_note(&store, 7, 1, kNowActSettleDispatchedUnconfirmed,
                            110);
    observed_window(&scene, 11, 0, 0, 0);
    now_act_settlement_observe_scene(&store, &scene, 3);
    CHECK(r->status == kNowActSettleDispatchedUnconfirmed,
          "a scene cannot settle a control act, and must not pretend to");

    /* What the verb does when its own re-read shows the control moved. */
    now_act_settlement_note(&store, 7, 1, kNowActSettleConfirmed, 120);
    CHECK(r->status == kNowActSettleConfirmed,
          "the application's own observation settles what no scene can");

    observed_window(&scene, 12, 0, 0, 0);
    now_act_settlement_observe_scene(&store, &scene, 3);
    CHECK(r->status == kNowActSettleConfirmed,
          "a later scene must not walk a confirmed act back");
}

/* And the same store must NOT be talked into confirming a control act
   the application could not observe: an unmoved control notes
   dispatched-but-unconfirmed, and that is where it stays. */
static void test_an_unobserved_control_act_stays_unconfirmed(void)
{
    NowActSettlementStore store;
    NowActSettlementSpec spec;
    NowActSettlementRecord *r;
    NowScene scene;

    now_act_settlement_reset(&store, 3);
    memset(&spec, 0, sizeof spec);
    spec.correlation_hi = 7;
    spec.correlation_lo = 2;
    spec.writer_epoch = 3;
    spec.target_psn_low = 42;
    spec.request_scene = 10;
    spec.kind = kNowPeekActKindControl;
    spec.operation = kNowPeekActOpControl;
    spec.postcondition = kNowActPostNone;

    r = now_act_settlement_begin(&store, &spec, 100);
    now_act_settlement_note(&store, 7, 2, kNowActSettleDispatchedUnconfirmed,
                            110);
    now_act_settlement_note_resident(&store, 7, 2, kNowPeekActStageArmed);
    observed_window(&scene, 11, 1, 40, 50);
    now_act_settlement_observe_scene(&store, &scene, 3);
    CHECK(r->status == kNowActSettleDispatchedUnconfirmed,
          "an unobserved control act is never confirmed by anything else");
}

int main(void)
{
    test_an_application_observation_settles_a_control_act();
    test_an_unobserved_control_act_stays_unconfirmed();
    test_late_success_and_reuse();
    test_postconditions_and_session();
    test_text_uses_postcondition_window();
    test_wire_encoding_is_bounded();
    test_menu_mark_postcondition();
    test_menu_mark_needs_the_resident_to_have_fired();
    if (failures) return 1;
    puts("act_settlement: ok");
    return 0;
}
