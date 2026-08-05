#ifndef NOW_SEMANTIC_POLICY_H
#define NOW_SEMANTIC_POLICY_H

#include "peek_table.h"

enum {
    /* 64 held one 64-control window, which was the right number while a
       scene could learn one control per pass. A batched reply carries 32
       at once and the corpus this plane is measured against has 122
       controls across ten panels, so 64 slots would now evict facts that
       were just earned. 128 * 56 bytes is 7 KiB of static in the
       application - paid once, and the alternative is re-asking for
       classes the resident already answered. */
    kNowSemanticPolicyMaxControls = 128,
    kNowSemanticPolicyMaxLists = 4,
    kNowSemanticPolicyMaxMenus = 2,
    /* Drain state for the windows currently being classified. A window
       is the batch's subject, so this is the batch's equivalent of a
       terminal menu: it is what stops the application asking again. */
    kNowSemanticPolicyMaxWindows = 8
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

/* How far a window's control hierarchy has been classified. `complete`
   is the claim that matters: without it the application would re-ask for
   a window whose controls the resident has already reported, forever,
   because a control the walk cannot reach never gains a fact. */
typedef struct {
    NowPeekU32 a5;
    NowPeekU32 window;
    NowPeekU32 expires_scene;
    NowPeekU32 next_start;
    NowPeekU32 total;
    NowPeekU32 complete;
} NowSemanticWindowFact;

typedef struct {
    NowPeekU32 owner_epoch;
    NowPeekU32 scene;
    NowSemanticControlClassFact controls[kNowSemanticPolicyMaxControls];
    NowSemanticListFact lists[kNowSemanticPolicyMaxLists];
    NowSemanticMenuFact menus[kNowSemanticPolicyMaxMenus];
    NowSemanticWindowFact windows[kNowSemanticPolicyMaxWindows];
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

/* A batched reply fills MANY class facts, one per record, each named by
   the control word the record carries. It also records how far the
   window has been drained. */
void now_semantic_policy_ingest_batch(NowSemanticPolicy *p,
                                      const NowPeekSemanticBatchCell *cell);
/* Is a batch request for this window worth making, and from which
   ordinal? 0 means no: either the window is fully classified, or a
   request for it is already in flight this scene. */
int now_semantic_policy_batch_plan(const NowSemanticPolicy *p, NowPeekU32 a5,
                                   NowPeekU32 window, NowPeekU32 *start);

#endif /* NOW_SEMANTIC_POLICY_H */
