#include "now_semantic_logic.h"

#include <string.h>

static NowPeekSemanticRecord *add_record(NowPeekSemanticCell *cell,
                                         NowPeekU16 kind,
                                         NowPeekU16 index,
                                         NowPeekU16 aux)
{
    NowPeekSemanticRecord *record;
    if (cell->response_record_count >= kNowPeekSemanticMaxRecords) {
        return NULL;
    }
    record = &cell->records[cell->response_record_count++];
    memset(record, 0, sizeof(*record));
    record->kind = kind;
    record->index = index;
    record->aux = aux;
    return record;
}

static void resolve_control(NowPeekSemanticCell *cell,
                            const NowSemanticSource *source)
{
    NowPeekSemanticRecord *record;
    NowPeekU16 kind = kNowPeekSemanticControlUnknown;
    NowPeekU16 true_length = 0;
    NowPeekU32 flags = 0;
    NowPeekU32 status;

    record = add_record(cell, kNowPeekSemanticRecordControlClass, 0, kind);
    if (record == NULL) {
        cell->response_status = kNowPeekSemanticStatusTruncated;
        return;
    }
    status = source->classify_control(
        source->ctx, cell->request_window, cell->request_object, &kind,
        record->text, kNowPeekSemanticTextMax, &true_length, &flags);
    record->aux = kind;
    record->status = (NowPeekU16)status;
    record->text_length = true_length;
    record->text_copied = true_length > kNowPeekSemanticTextMax
                        ? kNowPeekSemanticTextMax : true_length;
    record->flags = flags;
    if (true_length <= kNowPeekSemanticTextMax) {
        record->flags |= kNowPeekSemanticRecordTextComplete;
    } else if (status == kNowPeekSemanticStatusOk) {
        status = kNowPeekSemanticStatusTruncated;
        record->status = (NowPeekU16)status;
    }
    cell->response_total_count = 1;
    cell->response_status = status;
}

static void resolve_list(NowPeekSemanticCell *cell,
                         const NowSemanticSource *source)
{
    NowPeekU16 rows = 0, cols = 0, row, col;
    NowPeekU32 status = source->list_bounds(
        source->ctx, cell->request_window, cell->request_object, &rows, &cols);
    unsigned long total = (unsigned long)rows * cols;
    if (status != kNowPeekSemanticStatusOk) {
        cell->response_status = status;
        return;
    }
    cell->response_total_count = total > 0xffffUL ? 0xffff : (NowPeekU16)total;
    for (row = 0; row < rows; ++row) {
        for (col = 0; col < cols; ++col) {
            NowPeekSemanticRecord *record;
            NowPeekU16 true_length = 0;
            NowPeekU32 flags = 0;
            if (cell->response_record_count >= kNowPeekSemanticMaxRecords) {
                cell->response_status = kNowPeekSemanticStatusTruncated;
                return;
            }
            record = add_record(cell, kNowPeekSemanticRecordListCell,
                                (NowPeekU16)(row + 1), col);
            if (record == NULL) {
                cell->response_status = kNowPeekSemanticStatusTruncated;
                return;
            }
            status = source->list_cell(source->ctx, cell->request_object,
                                       row, col, record->text,
                                       kNowPeekSemanticTextMax,
                                       &true_length, &flags);
            record->status = (NowPeekU16)status;
            record->text_length = true_length;
            record->text_copied = true_length > kNowPeekSemanticTextMax
                                ? kNowPeekSemanticTextMax : true_length;
            record->flags = flags;
            if (status != kNowPeekSemanticStatusOk
                || true_length > kNowPeekSemanticTextMax) {
                cell->response_status = status == kNowPeekSemanticStatusOk
                    ? kNowPeekSemanticStatusTruncated : status;
                return;
            }
            record->flags |= kNowPeekSemanticRecordTextComplete;
        }
    }
    cell->response_status = kNowPeekSemanticStatusOk;
}

static void resolve_menu(NowPeekSemanticCell *cell,
                         const NowSemanticSource *source)
{
    NowPeekU16 count = 0, item;
    NowPeekU32 status = source->menu_count(
        source->ctx, cell->request_object, cell->request_object_aux, &count);
    if (status != kNowPeekSemanticStatusOk) {
        cell->response_status = status;
        return;
    }
    cell->response_total_count = count;
    for (item = 1; item <= count; ++item) {
        NowPeekSemanticRecord *record;
        NowPeekU16 true_length = 0;
        NowPeekU32 flags = 0;
        if (cell->response_record_count >= kNowPeekSemanticMaxRecords) {
            cell->response_status = kNowPeekSemanticStatusTruncated;
            return;
        }
        record = add_record(cell, kNowPeekSemanticRecordMenuItem, item, 0);
        if (record == NULL) {
            cell->response_status = kNowPeekSemanticStatusTruncated;
            return;
        }
        status = source->menu_item(source->ctx, cell->request_object, item,
                                   record->text, kNowPeekSemanticTextMax,
                                   &true_length, &flags);
        record->status = (NowPeekU16)status;
        record->text_length = true_length;
        record->text_copied = true_length > kNowPeekSemanticTextMax
                            ? kNowPeekSemanticTextMax : true_length;
        record->flags = flags;
        if (status != kNowPeekSemanticStatusOk
            || true_length > kNowPeekSemanticTextMax) {
            cell->response_status = status == kNowPeekSemanticStatusOk
                ? kNowPeekSemanticStatusTruncated : status;
            return;
        }
        record->flags |= kNowPeekSemanticRecordTextComplete;
    }
    cell->response_status = kNowPeekSemanticStatusOk;
}

void now_semantic_resolve(NowPeekSemanticCell *cell, NowPeekU32 ticks,
                          const NowSemanticSource *source)
{
    NowPeekU32 next = cell->response_generation + 2;
    volatile NowPeekU32 *commit = &cell->response_generation;
    if (next == 0 || (next & 1U)) next = 2;
    *commit = next - 1;
    cell->response_request_generation = cell->request_generation;
    cell->response_status = kNowPeekSemanticStatusUnsupported;
    cell->response_writer_epoch = cell->request_writer_epoch;
    cell->response_target_a5 = cell->request_target_a5;
    cell->response_scene_generation = cell->request_scene_generation;
    cell->response_window = cell->request_window;
    cell->response_object = cell->request_object;
    cell->response_object_aux = cell->request_object_aux;
    cell->response_served_ticks = ticks;
    cell->response_record_count = 0;
    cell->response_total_count = 0;
    if (source != NULL) {
        if (cell->request_op == kNowPeekSemanticOpControlClass
            && source->classify_control != NULL) resolve_control(cell, source);
        else if (cell->request_op == kNowPeekSemanticOpListCells
                 && source->list_bounds != NULL && source->list_cell != NULL)
            resolve_list(cell, source);
        else if (cell->request_op == kNowPeekSemanticOpSystemMenu
                 && source->menu_count != NULL && source->menu_item != NULL)
            resolve_menu(cell, source);
    }
    __asm__ __volatile__("" ::: "memory");
    *commit = next;
}

void now_semantic_refuse(NowPeekSemanticCell *cell, NowPeekU32 ticks,
                         NowPeekU32 status)
{
    volatile NowPeekU32 *commit = &cell->response_generation;
    now_semantic_resolve(cell, ticks, NULL);
    *commit = *commit - 1;
    cell->response_status = status;
    __asm__ __volatile__("" ::: "memory");
    *commit = *commit + 1;
}

static void resolve_batch(NowPeekSemanticBatchCell *cell,
                          const NowSemanticBatchSource *source)
{
    NowPeekU32 found[kNowPeekSemanticBatchWalkMax];
    NowPeekU16 total, i;
    NowPeekU32 start = cell->request_start;

    total = source->collect(source->ctx, cell->request_window, found,
                            (NowPeekU16)kNowPeekSemanticBatchWalkMax);
    if (total > kNowPeekSemanticBatchWalkMax) {
        total = (NowPeekU16)kNowPeekSemanticBatchWalkMax;
    }
    cell->response_total_count = total;
    if (total == 0) {
        /* The window is live enough to walk but has no control root, or
           it is not ours. Either way the honest answer is that nothing
           was found, not that something failed. */
        cell->response_status = kNowPeekSemanticStatusOk;
        return;
    }
    if (start >= total) {
        /* A resumed page that the window outgrew - it shrank between the
           request and the service. Not an error; there is simply nothing
           at that ordinal now. */
        cell->response_status = kNowPeekSemanticStatusOk;
        return;
    }
    for (i = (NowPeekU16)start; i < total; ++i) {
        NowPeekSemanticClassRecord *record;
        NowPeekU16 kind = kNowPeekSemanticControlUnknown;
        NowPeekU16 true_length = 0;
        NowPeekU32 flags = 0;
        NowPeekU32 status;

        if (cell->response_record_count >= kNowPeekSemanticMaxRecords) {
            /* More controls than one reply carries. Truncated is not a
               failure here: response_total_count says how many there
               are, and the next request resumes at this ordinal. */
            cell->response_status = kNowPeekSemanticStatusTruncated;
            return;
        }
        record = &cell->records[cell->response_record_count++];
        memset(record, 0, sizeof(*record));
        record->control = found[i];
        status = source->classify_member(
            source->ctx, cell->request_window, found[i], &kind,
            record->text, kNowPeekSemanticTextMax, &true_length, &flags);
        record->kind = kind;
        record->status = (NowPeekU16)status;
        record->text_length = true_length;
        record->text_copied = true_length > kNowPeekSemanticTextMax
                            ? kNowPeekSemanticTextMax : true_length;
        record->flags = flags;
        if (true_length <= kNowPeekSemanticTextMax) {
            record->flags |= kNowPeekSemanticRecordTextComplete;
        } else if (status == kNowPeekSemanticStatusOk) {
            record->status = kNowPeekSemanticStatusTruncated;
        }
        /* ONE CONTROL'S REFUSAL IS NOT THE BATCH'S. An unsupported custom
           control is a per-record verdict carried in that record; failing
           the whole reply on it would starve the classifier exactly the
           way the single-request transport already did. */
    }
    cell->response_status = kNowPeekSemanticStatusOk;
}

void now_semantic_batch_resolve(NowPeekSemanticBatchCell *cell,
                                NowPeekU32 ticks,
                                const NowSemanticBatchSource *source)
{
    NowPeekU32 next = cell->response_generation + 2;
    volatile NowPeekU32 *commit = &cell->response_generation;
    if (next == 0 || (next & 1U)) next = 2;
    *commit = next - 1;
    cell->response_request_generation = cell->request_generation;
    cell->response_status = kNowPeekSemanticStatusUnsupported;
    cell->response_writer_epoch = cell->request_writer_epoch;
    cell->response_target_a5 = cell->request_target_a5;
    cell->response_scene_generation = cell->request_scene_generation;
    cell->response_window = cell->request_window;
    cell->response_start = cell->request_start;
    cell->response_served_ticks = ticks;
    cell->response_record_count = 0;
    cell->response_total_count = 0;
    if (source != NULL && source->collect != NULL
        && source->classify_member != NULL) {
        resolve_batch(cell, source);
    }
    __asm__ __volatile__("" ::: "memory");
    *commit = next;
}

void now_semantic_batch_refuse(NowPeekSemanticBatchCell *cell,
                               NowPeekU32 ticks, NowPeekU32 status)
{
    volatile NowPeekU32 *commit = &cell->response_generation;
    now_semantic_batch_resolve(cell, ticks, NULL);
    *commit = *commit - 1;
    cell->response_status = status;
    __asm__ __volatile__("" ::: "memory");
    *commit = *commit + 1;
}
