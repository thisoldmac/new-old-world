#ifndef NOW_EXT_CURSOR_INPUT_H
#define NOW_EXT_CURSOR_INPUT_H

#include "peek_table.h"

enum {
    kNowCursorInputTriggerPosition = 1u << 0,
    kNowCursorInputTriggerButton = 1u << 1
};

typedef struct {
    NowPeekU32 sequence;
    NowPeekU32 samples;
    NowPeekU32 changes;
    NowPeekU32 trigger;
    NowPeekI32 h;
    NowPeekI32 v;
    NowPeekI32 owned_h;
    NowPeekI32 owned_v;
    NowPeekU32 buttons;
    NowPeekU32 physical_valid;
    NowPeekU32 owned_valid;
    NowPeekU32 debt_cancels;
} NowCursorInputDiagnostics;

NowPeekU32 now_ext_cursor_physical_input_seq(void);
void now_ext_cursor_remember_continuity_point(NowPeekI32 h, NowPeekI32 v);
void now_ext_cursor_cancel_task_apply(void);
void now_ext_cursor_input_diagnostics(NowCursorInputDiagnostics *out);

#endif /* NOW_EXT_CURSOR_INPUT_H */
