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

static NowSemanticControlFact *control_slot(NowSemanticPolicy *policy,
    NowPeekU32 a5, NowPeekU32 window, NowPeekU32 object)
{
    int i;
    int empty = -1;

    for (i = 0; i < kNowSemanticPolicyMaxControls; ++i) {
        NowSemanticControlFact *fact = &policy->controls[i];

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
        NowSemanticControlFact *fact = control_slot(
            policy, cell->response_target_a5, cell->response_window,
            cell->response_object);

        fact->class_status = cell->response_status;
        fact->class_kind = kNowPeekSemanticControlUnknown;
        fact->list_status = kNowPeekSemanticStatusNone;
        fact->selected_length = 0;
        fact->record_count = 0;
        fact->total_count = 0;
        if (cell->response_record_count != 0) {
            fact->class_kind = cell->records[0].aux;
        }
        fact->expires_scene = policy->scene + 4;
    } else if (cell->request_op == kNowPeekSemanticOpListCells) {
        NowSemanticControlFact *fact = control_slot(
            policy, cell->response_target_a5, cell->response_window,
            cell->response_object);

        fact->list_status = cell->response_status;
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
        const NowSemanticControlFact *fact = &policy->controls[i];

        if (alive(policy->scene, fact->expires_scene)
            && fact->a5 == a5 && fact->window == window
            && fact->object == control) {
            if (out != NULL) {
                *out = *fact;
            }
            return 1;
        }
    }
    return 0;
}
