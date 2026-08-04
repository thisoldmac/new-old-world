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
