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

    /* ---- P2's second cell: one reply fills many facts ---- */
    {
        NowPeekSemanticBatchCell batch;
        NowPeekU32 start = 99;
        int i;

        memset(&policy, 0, sizeof(policy));
        now_semantic_policy_begin(&policy, 7, 1);

        /* Before anything is known, a window is worth asking about from
           the top. This is what replaces 122 separate requests. */
        check(now_semantic_policy_batch_plan(&policy, 1, 2, &start)
                  && start == 0,
              "an unknown window is planned from ordinal 0");

        /* A full reply: twelve controls typed in one pass. */
        memset(&batch, 0, sizeof(batch));
        batch.response_writer_epoch = 7;
        batch.response_scene_generation = 1;
        batch.response_target_a5 = 1;
        batch.response_window = 2;
        batch.response_start = 0;
        batch.response_status = kNowPeekSemanticStatusOk;
        batch.response_record_count = 12;
        batch.response_total_count = 12;
        for (i = 0; i < 12; ++i) {
            batch.records[i].control = (NowPeekU32)(0x500 + i * 8);
            batch.records[i].kind = kNowPeekSemanticControlPushButton;
            batch.records[i].status = kNowPeekSemanticStatusOk;
        }
        batch.records[3].kind = kNowPeekSemanticControlListBox;
        now_semantic_policy_ingest_batch(&policy, &batch);

        for (i = 0; i < 12; ++i) {
            check(now_semantic_policy_control(&policy, 1, 2,
                                              (NowPeekU32)(0x500 + i * 8),
                                              &control),
                  "every control in the reply gained a fact");
        }
        check(now_semantic_policy_control(&policy, 1, 2, 0x500 + 3 * 8,
                                          &control)
                  && control.class_kind == kNowPeekSemanticControlListBox,
              "a fact is joined by the control its record named, not by order");
        check(!now_semantic_policy_control(&policy, 1, 2, 0x4444, &control),
              "a control the reply did not name gains nothing");
        check(!now_semantic_policy_control(&policy, 9, 2, 0x500, &control),
              "another process does not inherit these facts");

        /* A drained window stops being asked about - otherwise a control
           the walk cannot reach would re-request it forever. */
        check(!now_semantic_policy_batch_plan(&policy, 1, 2, &start),
              "a drained window is not asked again");
        check(now_semantic_policy_batch_plan(&policy, 1, 3, &start),
              "a different window is still worth asking about");
    }

    /* ---- a window larger than one reply is drained, not truncated ---- */
    {
        NowPeekSemanticBatchCell batch;
        NowPeekU32 start = 0;
        int i;

        memset(&policy, 0, sizeof(policy));
        now_semantic_policy_begin(&policy, 7, 1);

        memset(&batch, 0, sizeof(batch));
        batch.response_writer_epoch = 7;
        batch.response_scene_generation = 1;
        batch.response_target_a5 = 1;
        batch.response_window = 2;
        batch.response_start = 0;
        batch.response_status = kNowPeekSemanticStatusTruncated;
        batch.response_record_count = kNowPeekSemanticMaxRecords;
        batch.response_total_count = 40;
        for (i = 0; i < kNowPeekSemanticMaxRecords; ++i) {
            batch.records[i].control = (NowPeekU32)(0x800 + i * 8);
            batch.records[i].kind = kNowPeekSemanticControlCheckBox;
            batch.records[i].status = kNowPeekSemanticStatusOk;
        }
        now_semantic_policy_ingest_batch(&policy, &batch);

        check(now_semantic_policy_batch_plan(&policy, 1, 2, &start)
                  && start == kNowPeekSemanticMaxRecords,
              "a truncated window resumes where the page ended");

        /* The second page completes it. */
        memset(&batch, 0, sizeof(batch));
        batch.response_writer_epoch = 7;
        batch.response_scene_generation = 1;
        batch.response_target_a5 = 1;
        batch.response_window = 2;
        batch.response_start = kNowPeekSemanticMaxRecords;
        batch.response_status = kNowPeekSemanticStatusOk;
        batch.response_record_count = 8;
        batch.response_total_count = 40;
        for (i = 0; i < 8; ++i) {
            batch.records[i].control = (NowPeekU32)(0x900 + i * 8);
            batch.records[i].kind = kNowPeekSemanticControlRadioButton;
            batch.records[i].status = kNowPeekSemanticStatusOk;
        }
        now_semantic_policy_ingest_batch(&policy, &batch);
        check(!now_semantic_policy_batch_plan(&policy, 1, 2, &start),
              "the drained window stops asking");
        check(now_semantic_policy_control(&policy, 1, 2, 0x900, &control)
                  && control.class_kind
                        == kNowPeekSemanticControlRadioButton,
              "the second page's facts are kept too");
        check(now_semantic_policy_control(&policy, 1, 2, 0x800, &control),
              "and the first page's facts survive it");
    }

    /* ---- a reply the guard would not have passed is still not trusted ---- */
    {
        NowPeekSemanticBatchCell batch;

        memset(&policy, 0, sizeof(policy));
        now_semantic_policy_begin(&policy, 7, 5);
        memset(&batch, 0, sizeof(batch));
        batch.response_writer_epoch = 6;   /* a previous writer */
        batch.response_scene_generation = 5;
        batch.response_target_a5 = 1;
        batch.response_window = 2;
        batch.response_status = kNowPeekSemanticStatusOk;
        batch.response_record_count = 1;
        batch.response_total_count = 1;
        batch.records[0].control = 0x700;
        batch.records[0].kind = kNowPeekSemanticControlPushButton;
        now_semantic_policy_ingest_batch(&policy, &batch);
        check(!now_semantic_policy_control(&policy, 1, 2, 0x700, &control),
              "a reply from a previous writer is not ingested");

        batch.response_writer_epoch = 7;
        batch.response_scene_generation = 1;   /* older than two scenes */
        now_semantic_policy_ingest_batch(&policy, &batch);
        check(!now_semantic_policy_control(&policy, 1, 2, 0x700, &control),
              "a reply older than the freshness window is not ingested");

        batch.response_scene_generation = 5;
        batch.response_status = kNowPeekSemanticStatusInvalid;
        now_semantic_policy_ingest_batch(&policy, &batch);
        check(!now_semantic_policy_control(&policy, 1, 2, 0x700, &control),
              "a refused reply leaves no facts behind");
    }

    if (g_failures != 0) return 1;
    puts("semantic policy: terminal menu -> class -> list -> next control");
    return 0;
}
