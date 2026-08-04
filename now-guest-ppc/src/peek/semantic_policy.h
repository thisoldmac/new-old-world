#ifndef NOW_SEMANTIC_POLICY_H
#define NOW_SEMANTIC_POLICY_H

#include "peek_table.h"

enum {
    kNowSemanticPolicyMaxControls = 64,
    kNowSemanticPolicyMaxLists = 4,
    kNowSemanticPolicyMaxMenus = 2
};

typedef struct {
    NowPeekU32 a5;
    NowPeekU32 window;
    NowPeekU32 object;
    NowPeekU32 expires_scene;
    NowPeekU32 class_status;
    NowPeekU32 list_status;
    NowPeekU16 class_kind;
    NowPeekU16 class_value_length;
    unsigned char class_value[kNowPeekSemanticTextMax];
    NowPeekU16 selected_length;
    unsigned char selected[kNowPeekSemanticTextMax];
    NowPeekU16 record_count;
    NowPeekU16 total_count;
    NowPeekSemanticRecord records[kNowPeekSemanticMaxRecords];
} NowSemanticControlFact;

typedef struct {
    NowPeekU32 a5;
    NowPeekU32 window;
    NowPeekU32 object;
    NowPeekU32 expires_scene;
    NowPeekU32 status;
    NowPeekU16 kind;
    NowPeekU16 value_length;
    unsigned char value[kNowPeekSemanticTextMax];
} NowSemanticControlClassFact;

typedef struct {
    NowPeekU32 a5;
    NowPeekU32 window;
    NowPeekU32 object;
    NowPeekU32 expires_scene;
    NowPeekU32 status;
    NowPeekU16 selected_length;
    unsigned char selected[kNowPeekSemanticTextMax];
    NowPeekU16 record_count;
    NowPeekU16 total_count;
    NowPeekSemanticRecord records[kNowPeekSemanticMaxRecords];
} NowSemanticListFact;

typedef struct {
    NowPeekU32 a5;
    NowPeekU32 object;
    NowPeekU32 expires_scene;
    NowPeekU32 status;
    NowPeekI32 menu_id;
    NowPeekU16 record_count;
    NowPeekU16 total_count;
    NowPeekSemanticRecord records[kNowPeekSemanticMaxRecords];
} NowSemanticMenuFact;

typedef struct {
    NowPeekU32 owner_epoch;
    NowPeekU32 scene;
    NowSemanticControlClassFact controls[kNowSemanticPolicyMaxControls];
    NowSemanticListFact lists[kNowSemanticPolicyMaxLists];
    NowSemanticMenuFact menus[kNowSemanticPolicyMaxMenus];
} NowSemanticPolicy;

void now_semantic_policy_begin(NowSemanticPolicy *p, NowPeekU32 owner,
                               NowPeekU32 scene);
void now_semantic_policy_ingest(NowSemanticPolicy *p,
                                const NowPeekSemanticCell *cell);
int now_semantic_policy_menu_terminal(const NowSemanticPolicy *p,
    NowPeekU32 a5, NowPeekU32 menu, NowPeekI32 id, NowSemanticMenuFact *out);
int now_semantic_policy_control(const NowSemanticPolicy *p,
    NowPeekU32 a5, NowPeekU32 window, NowPeekU32 control,
    NowSemanticControlFact *out);

#endif /* NOW_SEMANTIC_POLICY_H */
