#include "semantic_client.h"

#include <Carbon.h>
#include <string.h>

#include "now_semantic_guard.h"
#include "peek.h"
#include "semantic_policy.h"

/* REQUEST PRIORITIES, and why they are in this order.
   ------------------------------------------------------------------
   The single cell serves one request per scene, so these decide what a
   scene learns. The old order - class 10, list 20, menu 30 - read as
   "cheap request, cheap priority" and was exactly backwards: a class
   fact lives 128 scenes and is the PREREQUISITE for a list request,
   while a list fact expires every 4. So the cheap prerequisite lost the
   cell to the expensive dependent, permanently, and 121 of 122 controls
   in the ten-panel corpus never carried a kind.

   Menus stay highest because they are terminal: a resolved menu never
   asks again, so it costs at most a scene or two and then stops
   competing. Classification now outranks list cells, because a list
   request cannot even be formed until its control is known to be a
   list box.

   offer() keeps the HIGHEST number, so a larger value here wins. */
enum {
    kPriorityListCells = 10,
    kPriorityControlClass = 20,
    kPrioritySystemMenu = 30
};

/* Batch priorities live on their own cell and so compete only with each
   other. The front process outranks the background - the app a person is
   using should not wait behind one they cannot see - but the background
   is no longer barred outright, which is what left background panels
   permanently blank. */
enum {
    kBatchPriorityBackground = 10,
    kBatchPriorityFront = 20
};

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
static int g_requestable;
static int g_front;

static NowPeekSemanticBatchCell g_batch_response;
static unsigned long g_batch_generation;
static int g_batch_scheduled;
static int g_batch_priority;
static unsigned long g_batch_window;
static unsigned long g_batch_start;
static unsigned long g_batch_a5;

void now_semantic_client_begin(unsigned long scene_generation)
{
    const NowPeekTable *table = now_peek_table();
    NowPeekU32 owner_epoch = table != NULL
        ? table->writer.resident_owner_epoch : 0;

    g_scene = scene_generation;
    g_a5 = 0;
    g_requestable = 0;
    g_front = 0;
    g_scheduled = 0;
    g_priority = 0;
    g_batch_scheduled = 0;
    g_batch_priority = 0;
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
    /* P2's second cell is copied under the same rules and by the same
       kind of committed read. It is absent on a resident that predates
       it, and absence is silence here, not an error. */
    if (table != NULL
        && now_semantic_batch_copy_response(table, TickCount(),
                                            &g_batch_response)
            == kNowSemanticCopyOk) {
        now_semantic_policy_ingest_batch(&g_policy, &g_batch_response);
    }
}

void now_semantic_client_aim(unsigned long a5, int requestable)
{
    g_a5 = a5;
    /* `requestable` still means "this is the front process". It gates the
       single cell, whose one lease a background process would spend on a
       panel nobody is looking at. It no longer gates the BATCH cell: that
       one has its own lease, so a background window can be classified
       whenever the front process has nothing left to ask. */
    g_requestable = requestable;
    g_front = requestable;
}

static void offer_batch(int priority, unsigned long window,
                        unsigned long start)
{
    if (g_a5 == 0 || priority <= g_batch_priority) {
        return;
    }
    g_batch_priority = priority;
    g_batch_window = window;
    g_batch_start = start;
    g_batch_a5 = g_a5;
    g_batch_scheduled = 1;
}

static void offer(int priority, unsigned long op, unsigned long window,
                  unsigned long object, long aux)
{
    if (g_a5 == 0 || !g_requestable || priority <= g_priority) {
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

static void publish_batch(NowPeekTable *table)
{
    volatile NowPeekU32 *commit;

    if (!g_batch_scheduled || !now_semantic_batch_ready(table)
        || table->writer.resident_owner_epoch == 0) {
        return;
    }
    /* One cell, one lease - the same rule the first cell learned.
       Rewriting an unserved request every scene advances its generation
       forever and the target never answers the one being waited on. */
    if (now_semantic_batch_pending(table, TickCount())) {
        return;
    }
    commit = &table->semantic_batch.request_generation;
    table->semantic_batch.request_writer_epoch =
        table->writer.resident_owner_epoch;
    table->semantic_batch.request_target_a5 = g_batch_a5;
    table->semantic_batch.request_scene_generation = g_scene;
    table->semantic_batch.request_window = g_batch_window;
    table->semantic_batch.request_start = g_batch_start;
    table->semantic_batch.request_deadline_ticks =
        TickCount() + kNowPeekSemanticLeaseTicks;
    ++g_batch_generation;
    if (g_batch_generation == 0) {
        ++g_batch_generation;
    }
    __asm__ __volatile__("" ::: "memory");
    *commit = g_batch_generation;
}

void now_semantic_client_end(void)
{
    NowPeekTable *table = (NowPeekTable *)now_peek_table();
    volatile NowPeekU32 *commit;

    publish_batch(table);
    if (!g_scheduled || !now_semantic_table_ready(table)
        || table->writer.resident_owner_epoch == 0) {
        return;
    }
    /* One resident cell means one lease. Rewriting the same unserved
       background request every scene advanced its generation forever and
       prevented the target from ever answering the generation the client
       was waiting for. The target either answers this request or its bounded
       lease expires before another one replaces it. */
    if (now_semantic_request_pending(table, TickCount())) {
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
    const char *role = NULL;

    if (!now_semantic_policy_control(
            &g_policy, g_a5, window_ptr, control, &fact)) {
        NowPeekU32 start = 0;

        /* ASK FOR THE WINDOW, NOT THE CONTROL. One batched request types
           every control this window has, so a panel is classified in one
           scene instead of one control per scene - which is the whole of
           the defect this path used to embody. */
        if (now_semantic_batch_ready(now_peek_table())
            && now_semantic_policy_batch_plan(&g_policy, (NowPeekU32)g_a5,
                                              (NowPeekU32)window_ptr,
                                              &start)) {
            offer_batch(g_front ? kBatchPriorityFront
                                : kBatchPriorityBackground,
                        window_ptr, start);
        } else {
            /* A resident that predates the batch cell, or a window it has
               finished walking without reaching this control. The exact
               single-control op still answers, one control per scene. */
            offer(kPriorityControlClass, kNowPeekSemanticOpControlClass,
                  window_ptr, control, 0);
        }
        return;
    }
    if (fact.class_status == kNowPeekSemanticStatusUnsupportedCustom) {
        now_scene_set_control_semantic_value(
            scene, window, index, "Unsupported custom control");
        return;
    }
    if (fact.class_status != kNowPeekSemanticStatusOk
        && fact.class_status != kNowPeekSemanticStatusTruncated
        && fact.class_status != kNowPeekSemanticStatusUnsupported) {
        now_scene_set_control_semantic_value(
            scene, window, index, "Semantic classification unavailable");
        return;
    }

    switch (fact.class_kind) {
    case kNowPeekSemanticControlListBox: role = "listBox"; break;
    case kNowPeekSemanticControlClock: role = "edit"; break;
    case kNowPeekSemanticControlGroupBox: role = "group"; break;
    case kNowPeekSemanticControlEditText: role = "edit"; break;
    case kNowPeekSemanticControlStaticText: role = "static"; break;
    case kNowPeekSemanticControlWindowHeader: role = "header"; break;
    case kNowPeekSemanticControlPushButton: role = "button"; break;
    case kNowPeekSemanticControlCheckBox: role = "checkbox"; break;
    case kNowPeekSemanticControlRadioButton: role = "radio"; break;
    case kNowPeekSemanticControlPopupButton: role = "popup"; break;
    case kNowPeekSemanticControlScrollBar: role = "scrollbar"; break;
    case kNowPeekSemanticControlDataBrowser: role = "dataBrowser"; break;
    case kNowPeekSemanticControlUserPane: role = "userPane"; break;
    case kNowPeekSemanticControlImageWell: role = "imageWell"; break;
    /* "systemControl" is a CLAIM: an Apple-signed control whose kind this
       side has not decoded. Only OtherSystem earns it. The default used
       to make it too, which meant Unknown - the value a fact carries when
       nothing determined a kind at all - was published as a decoded
       Apple control. That is the one answer this plane must never invent,
       because an undetermined control and an undecoded system control
       look identical downstream and only one of them is evidence. */
    case kNowPeekSemanticControlOtherSystem: role = "systemControl"; break;
    default: role = NULL; break;
    }
    if (role != NULL) {
        now_scene_set_control_role(scene, window, index, role);
    } else {
        /* No role at all, and a value that says why. A control with no
           role renders as the structural walk left it, which is honest:
           P1 still knows its rectangle, title and enablement. */
        now_scene_set_control_semantic_value(
            scene, window, index, "Control kind undetermined");
        return;
    }
    if (fact.class_value_length != 0) {
        char value[kNowPeekSemanticTextMax + 1];
        memcpy(value, fact.class_value, fact.class_value_length);
        value[fact.class_value_length] = '\0';
        now_scene_set_control_semantic_value(scene, window, index, value);
    } else if (fact.class_status == kNowPeekSemanticStatusUnsupported) {
        now_scene_set_control_semantic_value(
            scene, window, index, "Structured value unavailable");
    } else if (fact.class_kind == kNowPeekSemanticControlDataBrowser) {
        now_scene_set_control_semantic_value(
            scene, window, index, "Data browser content unavailable");
    } else if (fact.class_kind == kNowPeekSemanticControlUserPane
               || fact.class_kind == kNowPeekSemanticControlImageWell) {
        now_scene_set_control_semantic_value(
            scene, window, index, "Visual content unavailable");
    }

    if (fact.class_kind != kNowPeekSemanticControlListBox) return;
    if (fact.list_status == kNowPeekSemanticStatusNone) {
        offer(kPriorityListCells, kNowPeekSemanticOpListCells,
              window_ptr, control, 0);
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
    offer(kPrioritySystemMenu, kNowPeekSemanticOpSystemMenu, 0, menu, id);
}
