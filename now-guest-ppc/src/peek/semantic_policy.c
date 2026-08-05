#include "semantic_policy.h"

#include <string.h>

static int alive(NowPeekU32 scene, NowPeekU32 expires)
{
    return expires != 0 && (NowPeekI32)(scene - expires) <= 0;
}

static int response_scene_is_current(NowPeekU32 response, NowPeekU32 scene)
{
    NowPeekI32 age = (NowPeekI32)(scene - response);

    return age >= 0 && age <= 2;
}

void now_semantic_policy_begin(NowSemanticPolicy *policy, NowPeekU32 owner,
                               NowPeekU32 scene)
{
    if (policy == NULL) {
        return;
    }
    if (owner == 0 || policy->owner_epoch != owner
        || scene <= policy->scene) {
        memset(policy, 0, sizeof(*policy));
        policy->owner_epoch = owner;
    }
    policy->scene = scene;
}

static NowSemanticControlClassFact *control_slot(NowSemanticPolicy *policy,
    NowPeekU32 a5, NowPeekU32 window, NowPeekU32 object)
{
    int i;
    int empty = -1;

    for (i = 0; i < kNowSemanticPolicyMaxControls; ++i) {
        NowSemanticControlClassFact *fact = &policy->controls[i];

        if (fact->a5 == a5 && fact->window == window
            && fact->object == object) {
            return fact;
        }
        if (empty < 0 && !alive(policy->scene, fact->expires_scene)) {
            empty = i;
        }
    }
    if (empty < 0) {
        empty = 0;
    }
    memset(&policy->controls[empty], 0, sizeof(policy->controls[empty]));
    policy->controls[empty].a5 = a5;
    policy->controls[empty].window = window;
    policy->controls[empty].object = object;
    return &policy->controls[empty];
}

static NowSemanticListFact *list_slot(NowSemanticPolicy *policy,
    NowPeekU32 a5, NowPeekU32 window, NowPeekU32 object)
{
    int i;
    int empty = -1;

    for (i = 0; i < kNowSemanticPolicyMaxLists; ++i) {
        NowSemanticListFact *fact = &policy->lists[i];

        if (fact->a5 == a5 && fact->window == window
            && fact->object == object) {
            return fact;
        }
        if (empty < 0 && !alive(policy->scene, fact->expires_scene)) {
            empty = i;
        }
    }
    if (empty < 0) empty = 0;
    memset(&policy->lists[empty], 0, sizeof(policy->lists[empty]));
    policy->lists[empty].a5 = a5;
    policy->lists[empty].window = window;
    policy->lists[empty].object = object;
    return &policy->lists[empty];
}

static NowSemanticMenuFact *menu_slot(NowSemanticPolicy *policy,
    NowPeekU32 a5, NowPeekU32 object, NowPeekI32 menu_id)
{
    int i;
    int empty = -1;

    for (i = 0; i < kNowSemanticPolicyMaxMenus; ++i) {
        NowSemanticMenuFact *fact = &policy->menus[i];

        if (fact->a5 == a5 && fact->object == object
            && fact->menu_id == menu_id) {
            return fact;
        }
        if (empty < 0 && !alive(policy->scene, fact->expires_scene)) {
            empty = i;
        }
    }
    if (empty < 0) {
        empty = 0;
    }
    memset(&policy->menus[empty], 0, sizeof(policy->menus[empty]));
    policy->menus[empty].a5 = a5;
    policy->menus[empty].object = object;
    policy->menus[empty].menu_id = menu_id;
    return &policy->menus[empty];
}

void now_semantic_policy_ingest(NowSemanticPolicy *policy,
                                const NowPeekSemanticCell *cell)
{
    unsigned int i;

    if (policy == NULL || cell == NULL
        || cell->response_writer_epoch != policy->owner_epoch
        || !response_scene_is_current(cell->response_scene_generation,
                                      policy->scene)) {
        return;
    }
    if (cell->request_op == kNowPeekSemanticOpSystemMenu
        && (cell->response_status == kNowPeekSemanticStatusOk
            || cell->response_status == kNowPeekSemanticStatusTruncated
            || cell->response_status == kNowPeekSemanticStatusUnsupported)) {
        NowSemanticMenuFact *fact = menu_slot(
            policy, cell->response_target_a5, cell->response_object,
            cell->response_object_aux);

        fact->status = cell->response_status;
        fact->record_count = cell->response_record_count
            > kNowPeekSemanticMaxRecords
            ? kNowPeekSemanticMaxRecords : cell->response_record_count;
        fact->total_count = cell->response_total_count;
        memcpy(fact->records, cell->records,
               fact->record_count * sizeof(cell->records[0]));
        fact->expires_scene = policy->scene + 8;
    } else if (cell->request_op == kNowPeekSemanticOpControlClass) {
        NowSemanticControlClassFact *fact = control_slot(
            policy, cell->response_target_a5, cell->response_window,
            cell->response_object);

        fact->status = cell->response_status;
        fact->kind = kNowPeekSemanticControlUnknown;
        fact->value_length = 0;
        if (cell->response_record_count != 0) {
            const NowPeekSemanticRecord *record = &cell->records[0];
            fact->kind = record->aux;
            fact->value_length = record->text_copied;
            memcpy(fact->value, record->text, fact->value_length);
        }
        /* A class is tied to the exact window/control handles and writer
           epoch. Keep enough classes for a 64-control window so Sherlock
           does not expire its first controls before reaching its last. */
        fact->expires_scene = policy->scene + 128;
    } else if (cell->request_op == kNowPeekSemanticOpListCells) {
        NowSemanticListFact *fact = list_slot(
            policy, cell->response_target_a5, cell->response_window,
            cell->response_object);

        fact->status = cell->response_status;
        fact->selected_length = 0;
        fact->record_count = cell->response_record_count;
        fact->total_count = cell->response_total_count;
        memcpy(fact->records, cell->records,
               cell->response_record_count * sizeof(cell->records[0]));
        fact->expires_scene = policy->scene + 4;
        for (i = 0; i < cell->response_record_count; ++i) {
            if ((cell->records[i].flags
                    & kNowPeekSemanticRecordSelected) != 0) {
                fact->selected_length = cell->records[i].text_copied;
                memcpy(fact->selected, cell->records[i].text,
                       fact->selected_length);
                break;
            }
        }
    }
}

static NowSemanticWindowFact *window_slot(NowSemanticPolicy *policy,
    NowPeekU32 a5, NowPeekU32 window)
{
    int i;
    int empty = -1;

    for (i = 0; i < kNowSemanticPolicyMaxWindows; ++i) {
        NowSemanticWindowFact *fact = &policy->windows[i];

        if (fact->a5 == a5 && fact->window == window) {
            return fact;
        }
        if (empty < 0 && !alive(policy->scene, fact->expires_scene)) {
            empty = i;
        }
    }
    if (empty < 0) {
        empty = 0;
    }
    memset(&policy->windows[empty], 0, sizeof(policy->windows[empty]));
    policy->windows[empty].a5 = a5;
    policy->windows[empty].window = window;
    return &policy->windows[empty];
}

void now_semantic_policy_ingest_batch(NowSemanticPolicy *policy,
                                      const NowPeekSemanticBatchCell *cell)
{
    NowSemanticWindowFact *window;
    NowPeekU32 served;
    unsigned int i, count;

    if (policy == NULL || cell == NULL
        || cell->response_writer_epoch != policy->owner_epoch
        || !response_scene_is_current(cell->response_scene_generation,
                                      policy->scene)) {
        return;
    }
    if (cell->response_status != kNowPeekSemanticStatusOk
        && cell->response_status != kNowPeekSemanticStatusTruncated) {
        return;
    }
    count = cell->response_record_count;
    if (count > kNowPeekSemanticMaxRecords) {
        count = kNowPeekSemanticMaxRecords;
    }
    for (i = 0; i < count; ++i) {
        const NowPeekSemanticClassRecord *record = &cell->records[i];
        NowSemanticControlClassFact *fact;

        /* The record NAMES its control; nothing here infers identity from
           position. A record with no name was already refused by the
           guard, and is skipped rather than trusted if one arrives. */
        if (record->control == 0) {
            continue;
        }
        fact = control_slot(policy, cell->response_target_a5,
                            cell->response_window, record->control);
        fact->status = record->status;
        fact->kind = record->kind;
        fact->value_length = record->text_copied;
        memcpy(fact->value, record->text, fact->value_length);
        /* The same retention the single-control op earns: a class is
           tied to exact handles and a writer epoch, and is worth keeping
           far longer than a list's contents. */
        fact->expires_scene = policy->scene + 128;
    }

    window = window_slot(policy, cell->response_target_a5,
                         cell->response_window);
    served = cell->response_start + count;
    window->total = cell->response_total_count;
    window->next_start = served;
    /* Complete means the walk has nothing further to offer - not that
       every control gained a usable kind. A control the resident refused
       still holds a fact saying so, and asking again would get the same
       refusal. */
    window->complete = (cell->response_status == kNowPeekSemanticStatusOk
                        || served >= cell->response_total_count) ? 1 : 0;
    if (window->complete) {
        window->next_start = 0;
        /* Outlive the classes it produced, or the window would be re-
           walked while its own facts are still good. */
        window->expires_scene = policy->scene + 128;
    } else {
        /* A partial drain is retried soon; it is the only state that
           still owes work. */
        window->expires_scene = policy->scene + 8;
    }
}

int now_semantic_policy_batch_plan(const NowSemanticPolicy *policy,
                                   NowPeekU32 a5, NowPeekU32 window,
                                   NowPeekU32 *start)
{
    int i;

    if (policy == NULL || a5 == 0 || window == 0) {
        return 0;
    }
    for (i = 0; i < kNowSemanticPolicyMaxWindows; ++i) {
        const NowSemanticWindowFact *fact = &policy->windows[i];

        if (alive(policy->scene, fact->expires_scene)
            && fact->a5 == a5 && fact->window == window) {
            if (fact->complete) {
                return 0;
            }
            if (start != NULL) {
                *start = fact->next_start;
            }
            return 1;
        }
    }
    if (start != NULL) {
        *start = 0;
    }
    return 1;
}

int now_semantic_policy_menu_terminal(const NowSemanticPolicy *policy,
    NowPeekU32 a5, NowPeekU32 menu, NowPeekI32 id,
    NowSemanticMenuFact *out)
{
    int i;

    for (i = 0; i < kNowSemanticPolicyMaxMenus; ++i) {
        const NowSemanticMenuFact *fact = &policy->menus[i];

        if (alive(policy->scene, fact->expires_scene)
            && fact->a5 == a5 && fact->object == menu
            && fact->menu_id == id) {
            if (out != NULL) {
                *out = *fact;
            }
            return 1;
        }
    }
    return 0;
}

int now_semantic_policy_control(const NowSemanticPolicy *policy,
    NowPeekU32 a5, NowPeekU32 window, NowPeekU32 control,
    NowSemanticControlFact *out)
{
    int i;

    for (i = 0; i < kNowSemanticPolicyMaxControls; ++i) {
        const NowSemanticControlClassFact *fact = &policy->controls[i];

        if (alive(policy->scene, fact->expires_scene)
            && fact->a5 == a5 && fact->window == window
            && fact->object == control) {
            if (out != NULL) {
                int j;
                memset(out, 0, sizeof(*out));
                out->a5 = fact->a5;
                out->window = fact->window;
                out->object = fact->object;
                out->expires_scene = fact->expires_scene;
                out->class_status = fact->status;
                out->class_kind = fact->kind;
                out->class_value_length = fact->value_length;
                memcpy(out->class_value, fact->value, fact->value_length);
                for (j = 0; j < kNowSemanticPolicyMaxLists; ++j) {
                    const NowSemanticListFact *list = &policy->lists[j];
                    if (alive(policy->scene, list->expires_scene)
                        && list->a5 == a5 && list->window == window
                        && list->object == control) {
                        out->list_status = list->status;
                        out->selected_length = list->selected_length;
                        memcpy(out->selected, list->selected,
                               list->selected_length);
                        out->record_count = list->record_count;
                        out->total_count = list->total_count;
                        memcpy(out->records, list->records,
                               list->record_count * sizeof(list->records[0]));
                        break;
                    }
                }
            }
            return 1;
        }
    }
    return 0;
}
