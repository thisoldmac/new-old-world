#ifndef NOW_SEMANTIC_LOGIC_H
#define NOW_SEMANTIC_LOGIC_H

#include "peek_table.h"

typedef struct {
    void *ctx;
    NowPeekU32 (*classify_control)(void *ctx, NowPeekU32 window,
                                   NowPeekU32 control, NowPeekU16 *kind,
                                   unsigned char *text, NowPeekU16 cap,
                                   NowPeekU16 *true_length,
                                   NowPeekU32 *flags);
    NowPeekU32 (*list_bounds)(void *ctx, NowPeekU32 window,
                              NowPeekU32 control, NowPeekU16 *rows,
                              NowPeekU16 *cols);
    /* Text callbacks set true_length and copy exactly min(true_length, cap)
       bytes. They never append a terminator or silently shorten the copy. */
    NowPeekU32 (*list_cell)(void *ctx, NowPeekU32 control,
                            NowPeekU16 row, NowPeekU16 col,
                            unsigned char *text, NowPeekU16 cap,
                            NowPeekU16 *true_length, NowPeekU32 *flags);
    NowPeekU32 (*menu_count)(void *ctx, NowPeekU32 menu,
                             NowPeekI32 menu_id, NowPeekU16 *count);
    NowPeekU32 (*menu_item)(void *ctx, NowPeekU32 menu, NowPeekU16 item,
                            unsigned char *text, NowPeekU16 cap,
                            NowPeekU16 *true_length, NowPeekU32 *flags);
} NowSemanticSource;

void now_semantic_resolve(NowPeekSemanticCell *cell, NowPeekU32 ticks,
                          const NowSemanticSource *source);
void now_semantic_refuse(NowPeekSemanticCell *cell, NowPeekU32 ticks,
                         NowPeekU32 status);

/* The batch source is two calls, not one, and the split is the point.
   `collect` performs the ONE bounded hierarchy walk that serving any
   control request already pays for, and hands back the controls it
   enumerated. `classify_member` then types a control the walk itself
   produced, so it must NOT re-prove membership - re-proving it per
   control is what would turn one walk into thirty-two. */
typedef struct {
    void *ctx;
    NowPeekU16 (*collect)(void *ctx, NowPeekU32 window, NowPeekU32 *out,
                          NowPeekU16 cap);
    NowPeekU32 (*classify_member)(void *ctx, NowPeekU32 window,
                                  NowPeekU32 control, NowPeekU16 *kind,
                                  unsigned char *text, NowPeekU16 cap,
                                  NowPeekU16 *true_length,
                                  NowPeekU32 *flags);
} NowSemanticBatchSource;

void now_semantic_batch_resolve(NowPeekSemanticBatchCell *cell,
                                NowPeekU32 ticks,
                                const NowSemanticBatchSource *source);
void now_semantic_batch_refuse(NowPeekSemanticBatchCell *cell,
                               NowPeekU32 ticks, NowPeekU32 status);

#endif
