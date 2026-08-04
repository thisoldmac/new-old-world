#include "semantic_client.h"

#include <Carbon.h>
#include <string.h>

#include "now_semantic_guard.h"
#include "peek.h"
#include "semantic_policy.h"

static NowPeekSemanticCell g_response;
static NowSemanticPolicy g_policy;
static unsigned long g_scene;
static unsigned long g_a5;
static unsigned long g_generation;
static int g_scheduled;
static int g_priority;
static unsigned long g_op;
static unsigned long g_window;
static unsigned long g_object;
static unsigned long g_candidate_a5;
static long g_aux;

void now_semantic_client_begin(unsigned long scene_generation)
{
    const NowPeekTable *table = now_peek_table();
    NowPeekU32 owner_epoch = table != NULL
        ? table->writer.resident_owner_epoch : 0;

    g_scene = scene_generation;
    g_a5 = 0;
    g_scheduled = 0;
    g_priority = 0;
    now_semantic_policy_begin(&g_policy, owner_epoch,
                              (NowPeekU32)scene_generation);
    if (table != NULL
        && now_semantic_copy_response(table, TickCount(), &g_response)
            == kNowSemanticCopyOk) {
        /* This is the only response-to-policy path. The policy rejects a
           prior writer epoch, future scene, or response older than two
           scenes before any scene join can see it. */
        now_semantic_policy_ingest(&g_policy, &g_response);
    }
}

void now_semantic_client_aim(unsigned long a5)
{
    g_a5 = a5;
}

static void offer(int priority, unsigned long op, unsigned long window,
                  unsigned long object, long aux)
{
    if (g_a5 == 0 || priority <= g_priority) {
        return;
    }
    g_priority = priority;
    g_op = op;
    g_window = window;
    g_object = object;
    g_aux = aux;
    g_candidate_a5 = g_a5;
    g_scheduled = 1;
}

void now_semantic_client_end(void)
{
    NowPeekTable *table = (NowPeekTable *)now_peek_table();
    volatile NowPeekU32 *commit;

    if (!g_scheduled || !now_semantic_table_ready(table)
        || table->writer.resident_owner_epoch == 0) {
        return;
    }
    commit = &table->semantic.request_generation;
    table->semantic.request_op = g_op;
    table->semantic.request_writer_epoch =
        table->writer.resident_owner_epoch;
    table->semantic.request_target_a5 = g_candidate_a5;
    table->semantic.request_scene_generation = g_scene;
    table->semantic.request_window = g_window;
    table->semantic.request_object = g_object;
    table->semantic.request_object_aux = g_aux;
    table->semantic.request_deadline_ticks =
        TickCount() + kNowPeekSemanticLeaseTicks;
    ++g_generation;
    if (g_generation == 0) {
        ++g_generation;
    }
    __asm__ __volatile__("" ::: "memory");
    *commit = g_generation;
}

void now_semantic_client_join_control(NowScene *scene, int window, int index,
                                      unsigned long window_ptr,
                                      unsigned long control)
{
    NowSemanticControlFact fact;
    unsigned int i;
    int complete;

    if (!now_semantic_policy_control(
            &g_policy, g_a5, window_ptr, control, &fact)) {
        offer(10, kNowPeekSemanticOpControlClass,
              window_ptr, control, 0);
        return;
    }
    if (fact.class_status == kNowPeekSemanticStatusUnsupportedCustom) {
        now_scene_set_control_semantic_value(
            scene, window, index, "Unsupported custom control");
        return;
    }
    if (fact.class_status != kNowPeekSemanticStatusOk
        || fact.class_kind != kNowPeekSemanticControlStandard) {
        now_scene_set_control_semantic_value(
            scene, window, index, "Semantic classification unavailable");
        return;
    }

    now_scene_set_control_role(scene, window, index, "listBox");
    if (fact.list_status == kNowPeekSemanticStatusNone) {
        offer(20, kNowPeekSemanticOpListCells, window_ptr, control, 0);
    } else if (fact.list_status == kNowPeekSemanticStatusOk
               || fact.list_status == kNowPeekSemanticStatusTruncated) {
        char value[kNowPeekSemanticTextMax + 1];
        unsigned int length = fact.selected_length;

        memcpy(value, fact.selected, length);
        value[length] = '\0';
        now_scene_set_control_semantic_value(
            scene, window, index,
            length != 0 ? value : "Selected value unavailable");
        complete = fact.list_status == kNowPeekSemanticStatusOk
            && fact.record_count == fact.total_count;
        for (i = 0; i < fact.record_count; ++i) {
            const NowPeekSemanticRecord *record = &fact.records[i];

            if (record->kind != kNowPeekSemanticRecordListCell
                || record->status != kNowPeekSemanticStatusOk
                || (record->flags
                    & kNowPeekSemanticRecordTextComplete) == 0) {
                complete = 0;
            }
        }
        now_scene_begin_control_list(scene, window, index,
                                     fact.total_count, complete);
        for (i = 0; i < fact.record_count; ++i) {
            const NowPeekSemanticRecord *record = &fact.records[i];
            char text[kNowPeekSemanticTextMax + 1];

            if (record->kind != kNowPeekSemanticRecordListCell
                || record->status != kNowPeekSemanticStatusOk
                || (record->flags
                    & kNowPeekSemanticRecordTextComplete) == 0) {
                continue;
            }
            memcpy(text, record->text, record->text_copied);
            text[record->text_copied] = '\0';
            if (!now_scene_add_control_list_cell(
                    scene, window, index, (short)record->index,
                    (short)record->aux, text,
                    (record->flags
                     & kNowPeekSemanticRecordSelected) != 0)) {
                break;
            }
        }
    } else {
        now_scene_set_control_semantic_value(
            scene, window, index, "List content unavailable");
    }
}

static void append_menu_records(NowScene *scene, int row,
                                const NowSemanticMenuFact *fact)
{
    unsigned int i;

    if (fact->status == kNowPeekSemanticStatusUnsupported) {
        (void)now_scene_add_menu_item(
            scene, row, "System menu unavailable", 1, 0, 0, 0, '\0');
        return;
    }
    if (fact->status == kNowPeekSemanticStatusTruncated
        || fact->total_count > fact->record_count) {
        scene->menus_truncated = 1;
    }
    for (i = 0; i < fact->record_count; ++i) {
        const NowPeekSemanticRecord *record = &fact->records[i];
        char text[kNowPeekSemanticTextMax + 1];
        unsigned int length = record->text_copied;

        memcpy(text, record->text, length);
        text[length] = '\0';
        (void)now_scene_add_menu_item(
            scene, row, text, record->index,
            (record->flags & kNowPeekSemanticRecordSeparator) != 0,
            (record->flags & kNowPeekSemanticRecordEnabled) != 0,
            (record->flags & kNowPeekSemanticRecordChecked) != 0, '\0');
    }
}

void now_semantic_client_join_menu(NowScene *scene, int row,
                                   unsigned long menu, short id)
{
    NowSemanticMenuFact fact;

    if (now_semantic_policy_menu_terminal(
            &g_policy, g_a5, menu, id, &fact)) {
        append_menu_records(scene, row, &fact);
        return;
    }
    offer(30, kNowPeekSemanticOpSystemMenu, 0, menu, id);
}
