#ifndef NOW_ACT_SETTLEMENT_H
#define NOW_ACT_SETTLEMENT_H

/* Application-owned action settlement. Resident requested/armed/fired is
   retained as mechanism evidence, but only a later normal-context scene (or
   an explicit application observation) may confirm an effect. */

#include "peek_table.h"
#include "scene.h"

enum { kNowActSettlementCapacity = 16 };

typedef enum {
    kNowActSettleUnknown = 0,
    kNowActSettleDispatchedUnconfirmed = 1,
    kNowActSettleRefused = 2,
    kNowActSettleTimedOut = 3,
    kNowActSettleSessionChanged = 4,
    kNowActSettleConfirmed = 5
} NowActSettlementStatus;

typedef enum {
    kNowActPostNone = 0,
    kNowActPostWindow = 1,
    kNowActPostText = 2,
    kNowActPostFrontProcess = 3,
    /* THE MENU'S OWN CHECKMARK. A menu that marks one of its items is
       stating which one is current - the Finder's View menu is the
       canonical case - so after a press on such a menu, the mark landing
       on the item pressed is the application's own confirmation that its
       handler ran. Before this, EVERY menu act carried kNowActPostNone
       and could therefore never be confirmed: `as Buttons` switched the
       window and reported `dispatched-but-unconfirmed` with the proof
       sitting in the very next scene (watched 2026-08-07). */
    kNowActPostMenuMark = 4
} NowActPostcondition;

typedef struct {
    NowPeekU32 correlation_hi, correlation_lo;
    NowPeekU32 writer_epoch;
    NowPeekU32 target_psn_high, target_psn_low;
    NowPeekU32 request_scene;
    NowPeekU32 kind, operation, object;
    NowPeekU32 post_object;
    NowPeekI32 aux;
    NowActPostcondition postcondition;
    NowPeekI32 expected_a, expected_b;
    NowPeekU16 text_length;
    unsigned char text[kNowPeekActTextMax];
} NowActSettlementSpec;

typedef struct {
    NowActSettlementSpec spec;
    NowActSettlementStatus status;
    NowPeekU32 resident_stage;
    NowPeekU32 created_ticks;
    NowPeekU32 timed_out_ticks;       /* retained after later confirmation */
    NowPeekU32 terminal_ticks;
    NowPeekU32 confirmed_scene;
} NowActSettlementRecord;

typedef struct {
    NowActSettlementRecord records[kNowActSettlementCapacity];
    unsigned short count;
    unsigned short next;
    NowPeekU32 writer_epoch;
} NowActSettlementStore;

void now_act_settlement_reset(NowActSettlementStore *store,
                              NowPeekU32 writer_epoch);
NowActSettlementRecord *now_act_settlement_begin(
    NowActSettlementStore *store, const NowActSettlementSpec *spec,
    NowPeekU32 ticks);
NowActSettlementRecord *now_act_settlement_find(
    NowActSettlementStore *store, NowPeekU32 correlation_hi,
    NowPeekU32 correlation_lo);
void now_act_settlement_note(NowActSettlementStore *store,
                             NowPeekU32 correlation_hi,
                             NowPeekU32 correlation_lo,
                             NowActSettlementStatus status,
                             NowPeekU32 ticks);
void now_act_settlement_note_resident(NowActSettlementStore *store,
                                      NowPeekU32 correlation_hi,
                                      NowPeekU32 correlation_lo,
                                      NowPeekU32 stage);
void now_act_settlement_observe_scene(NowActSettlementStore *store,
                                      const NowScene *scene,
                                      NowPeekU32 writer_epoch);
void now_act_settlement_change_session(NowActSettlementStore *store,
                                       NowPeekU32 writer_epoch,
                                       NowPeekU32 ticks);
const char *now_act_settlement_status_code(NowActSettlementStatus status);
long now_act_settlement_encode(const NowActSettlementStore *store,
                               char *out, long cap);

#endif
