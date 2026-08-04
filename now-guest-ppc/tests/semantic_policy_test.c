#include <stdio.h>
#include <string.h>

#include "semantic_policy.h"

static int g_failures;

static void check(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        ++g_failures;
    }
}

static void make_response(NowPeekSemanticCell *cell,
                          NowPeekU32 scene_generation,
                          NowPeekU32 operation,
                          NowPeekU32 object)
{
    NowPeekU32 window = operation == kNowPeekSemanticOpSystemMenu ? 0 : 2;
    NowPeekI32 aux = operation == kNowPeekSemanticOpSystemMenu ? 128 : 0;

    memset(cell, 0, sizeof(*cell));
    cell->request_op = operation;
    cell->request_target_a5 = 1;
    cell->request_window = window;
    cell->request_object = object;
    cell->request_object_aux = aux;
    cell->response_writer_epoch = 7;
    cell->response_target_a5 = 1;
    cell->response_scene_generation = scene_generation;
    cell->response_window = window;
    cell->response_object = object;
    cell->response_object_aux = aux;
}

int main(void)
{
    NowSemanticPolicy policy;
    NowPeekSemanticCell cell;
    NowSemanticControlFact control;
    NowSemanticMenuFact menu;

    memset(&policy, 0, sizeof(policy));
    now_semantic_policy_begin(&policy, 7, 1);
    check(!now_semantic_policy_menu_terminal(&policy, 1, 9, 128, &menu),
          "scene 1 requests menu");

    make_response(&cell, 1, kNowPeekSemanticOpSystemMenu, 9);
    cell.response_status = kNowPeekSemanticStatusUnsupported;
    now_semantic_policy_begin(&policy, 7, 2);
    now_semantic_policy_ingest(&policy, &cell);
    check(now_semantic_policy_menu_terminal(&policy, 1, 9, 128, &menu) &&
              menu.status == kNowPeekSemanticStatusUnsupported,
          "scene 2 caches terminal menu refusal");
    check(!now_semantic_policy_control(&policy, 1, 2, 3, &control),
          "scene 2 advances to control class");

    make_response(&cell, 2, kNowPeekSemanticOpControlClass, 3);
    cell.response_status = kNowPeekSemanticStatusOk;
    cell.response_record_count = 1;
    cell.records[0].aux = kNowPeekSemanticControlStandard;
    cell.records[0].text_copied = 8;
    memcpy(cell.records[0].text, "8/4/2026", 8);
    now_semantic_policy_begin(&policy, 7, 3);
    now_semantic_policy_ingest(&policy, &cell);
    check(now_semantic_policy_control(&policy, 1, 2, 3, &control) &&
              control.class_kind == kNowPeekSemanticControlStandard &&
              control.class_value_length == 8 &&
              memcmp(control.class_value, "8/4/2026", 8) == 0 &&
              control.list_status == 0,
          "scene 3 advances class to list request");

    make_response(&cell, 3, kNowPeekSemanticOpListCells, 3);
    cell.response_status = kNowPeekSemanticStatusOk;
    cell.response_record_count = 2;
    cell.response_total_count = 2;
    cell.records[0].kind = kNowPeekSemanticRecordListCell;
    cell.records[0].index = 1;
    cell.records[0].aux = 0;
    cell.records[0].flags = kNowPeekSemanticRecordSelected;
    cell.records[0].text_copied = 4;
    memcpy(cell.records[0].text, "Rome", 4);
    cell.records[1].kind = kNowPeekSemanticRecordListCell;
    cell.records[1].index = 1;
    cell.records[1].aux = 1;
    cell.records[1].text_copied = 5;
    memcpy(cell.records[1].text, "Italy", 5);
    now_semantic_policy_begin(&policy, 7, 4);
    now_semantic_policy_ingest(&policy, &cell);
    check(now_semantic_policy_control(&policy, 1, 2, 3, &control) &&
              control.list_status == kNowPeekSemanticStatusOk &&
              control.selected_length == 4 && control.record_count == 2
              && control.total_count == 2
              && control.records[1].index == 1
              && control.records[1].aux == 1
              && memcmp(control.records[1].text, "Italy", 5) == 0,
          "scene 4 retains the complete bounded list result");
    check(!now_semantic_policy_control(&policy, 1, 2, 4, &control),
          "scene 4 advances to next control, not control 1 again");

    make_response(&cell, 99, kNowPeekSemanticOpControlClass, 4);
    cell.response_status = kNowPeekSemanticStatusOk;
    now_semantic_policy_ingest(&policy, &cell);
    check(!now_semantic_policy_control(&policy, 1, 2, 4, &control),
          "future scene identity is refused");

    now_semantic_policy_begin(&policy, 8, 5);
    check(!now_semantic_policy_control(&policy, 1, 2, 3, &control),
          "owner epoch change resets facts");
    now_semantic_policy_begin(&policy, 8, 4);
    check(!now_semantic_policy_menu_terminal(&policy, 1, 9, 128, &menu),
          "scene regression resets facts");

    make_response(&cell, 4, kNowPeekSemanticOpSystemMenu, 9);
    cell.response_writer_epoch = 8;
    cell.response_status = kNowPeekSemanticStatusOk;
    cell.response_record_count = 2;
    cell.response_total_count = 2;
    cell.records[0].index = 1;
    cell.records[0].text_copied = 3;
    memcpy(cell.records[0].text, "One", 3);
    cell.records[1].index = 2;
    cell.records[1].text_copied = 3;
    memcpy(cell.records[1].text, "Two", 3);
    now_semantic_policy_begin(&policy, 8, 5);
    now_semantic_policy_ingest(&policy, &cell);
    now_semantic_policy_begin(&policy, 8, 6);
    check(now_semantic_policy_menu_terminal(&policy, 1, 9, 128, &menu) &&
              menu.record_count == 2 &&
              memcmp(menu.records[1].text, "Two", 3) == 0,
          "successful menu rows persist without re-request flicker");

    make_response(&cell, 6, kNowPeekSemanticOpControlClass, 4);
    cell.response_writer_epoch = 7;
    cell.response_status = kNowPeekSemanticStatusOk;
    now_semantic_policy_ingest(&policy, &cell);
    check(!now_semantic_policy_control(&policy, 1, 2, 4, &control),
          "prior owner response cannot cross sessions");
    cell.response_writer_epoch = 8;
    cell.response_scene_generation = 99;
    now_semantic_policy_ingest(&policy, &cell);
    check(!now_semantic_policy_control(&policy, 1, 2, 4, &control),
          "future response cannot join an older scene");
    cell.response_scene_generation = 1;
    now_semantic_policy_ingest(&policy, &cell);
    check(!now_semantic_policy_control(&policy, 1, 2, 4, &control),
          "old response cannot bypass policy freshness");

    /* Sherlock has 35 controls. A compact, long-lived class cache must reach
       the last without expiring the first and restarting forever. */
    memset(&policy, 0, sizeof(policy));
    now_semantic_policy_begin(&policy, 7, 1);
    {
        int i;
        for (i = 0; i < 35; ++i) {
            make_response(&cell, (NowPeekU32)(i + 1),
                          kNowPeekSemanticOpControlClass,
                          (NowPeekU32)(100 + i));
            cell.response_status = kNowPeekSemanticStatusOk;
            cell.response_record_count = 1;
            cell.records[0].aux = kNowPeekSemanticControlWindowHeader;
            now_semantic_policy_begin(&policy, 7, (NowPeekU32)(i + 2));
            now_semantic_policy_ingest(&policy, &cell);
        }
    }
    check(now_semantic_policy_control(&policy, 1, 2, 100, &control)
              && control.class_kind
                    == kNowPeekSemanticControlWindowHeader,
          "35-control window retains its first typed control");
    check(now_semantic_policy_control(&policy, 1, 2, 134, &control),
          "35-control window reaches its last typed control");

    if (g_failures != 0) return 1;
    puts("semantic policy: terminal menu -> class -> list -> next control");
    return 0;
}
