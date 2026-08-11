#include "now_semantic_guard.h"

#include <stddef.h>

static int expired(NowPeekU32 ticks, NowPeekU32 deadline)
{
    return (NowPeekI32)(ticks - deadline) > 0;
}

int now_semantic_table_ready(volatile const NowPeekTable *table)
{
    unsigned long need;

    if (table == NULL) {
        return 0;
    }
    need = (unsigned long)offsetof(NowPeekTable, semantic)
         + (unsigned long)sizeof(NowPeekSemanticCell);
    return table->magic == (NowPeekU32)kNowPeekTableMagic
        && table->ext_major == kNowPeekExtMajor
        && table->length >= need
        && (table->caps & kNowPeekTableCapTree) != 0
        && table->semantic_format == kNowPeekSemanticFormatV2
        && table->semantic_length == sizeof(NowPeekSemanticCell);
}

int now_semantic_request_pending(volatile const NowPeekTable *table,
                                 NowPeekU32 ticks)
{
    volatile const NowPeekSemanticCell *cell;

    if (!now_semantic_table_ready(table)
        || table->writer.resident_owner_epoch == 0) {
        return 0;
    }
    cell = &table->semantic;
    return cell->request_generation != 0
        && cell->request_writer_epoch == table->writer.resident_owner_epoch
        && cell->response_request_generation != cell->request_generation
        && !expired(ticks, cell->request_deadline_ticks);
}

NowSemanticRequestVerdict now_semantic_request_verdict(
    volatile const NowPeekTable *table, NowPeekU32 current_a5,
    NowPeekU32 ticks)
{
    volatile const NowPeekSemanticCell *cell;

    if (!now_semantic_table_ready(table)
        || (table->arm_active & kNowPeekTableCapTree) == 0) {
        return kNowSemanticNoPlane;
    }
    cell = &table->semantic;
    if (cell->request_generation == 0
        || cell->request_op < kNowPeekSemanticOpControlClass
        || cell->request_op > kNowPeekSemanticOpSystemMenu
        || cell->request_writer_epoch == 0
        || cell->request_writer_epoch != table->writer.resident_owner_epoch
        || cell->request_target_a5 == 0
        || cell->request_object == 0
        || (cell->request_op != kNowPeekSemanticOpSystemMenu
            && cell->request_window == 0)) {
        return kNowSemanticBadRequest;
    }
    if (cell->request_target_a5 != current_a5) {
        return kNowSemanticWrongTarget;
    }
    if (expired(ticks, cell->request_deadline_ticks)) {
        return kNowSemanticStale;
    }
    return kNowSemanticAccept;
}

static int record_shape_ok(const NowPeekSemanticRecord *record,
                           NowPeekU32 op)
{
    NowPeekU16 want;

    if (op == kNowPeekSemanticOpControlClass) {
        want = kNowPeekSemanticRecordControlClass;
    } else if (op == kNowPeekSemanticOpListCells) {
        want = kNowPeekSemanticRecordListCell;
    } else if (op == kNowPeekSemanticOpSystemMenu) {
        want = kNowPeekSemanticRecordMenuItem;
    } else {
        return 0;
    }
    return record->kind == want
        && record->status >= kNowPeekSemanticStatusOk
        && record->status <= kNowPeekSemanticStatusStale
        && record->text_copied <= kNowPeekSemanticTextMax
        && record->text_copied <= record->text_length
        && ((record->flags & kNowPeekSemanticRecordTextComplete) == 0
            || record->text_copied == record->text_length);
}

/* The resident publishes between application event-loop passes, but it still
   owns this memory. Keep every source load volatile and copy bytewise so the
   compiler cannot turn the generation reread below into a cached value. */
static void copy_from_resident(void *dst, volatile const void *src, size_t len)
{
    unsigned char *to = (unsigned char *)dst;
    volatile const unsigned char *from =
        (volatile const unsigned char *)src;
    size_t i;

    for (i = 0; i < len; ++i) {
        to[i] = from[i];
    }
}

NowSemanticCopyVerdict now_semantic_copy_response(
    volatile const NowPeekTable *table, NowPeekU32 ticks,
    NowPeekSemanticCell *out)
{
    volatile const NowPeekSemanticCell *cell;
    NowPeekU32 generation;
    unsigned int i;

    if (out == NULL || !now_semantic_table_ready(table)) {
        return kNowSemanticCopyNoPlane;
    }
    cell = &table->semantic;
    generation = cell->response_generation;
    if (generation == 0 || (generation & 1U) != 0) {
        return kNowSemanticCopyInProgress;
    }
    copy_from_resident(out, cell, sizeof(*out));
    if (cell->response_generation != generation
        || out->response_generation != generation) {
        return kNowSemanticCopyInProgress;
    }
    if (out->response_request_generation != out->request_generation
        || out->response_writer_epoch != out->request_writer_epoch
        || out->response_target_a5 != out->request_target_a5
        || out->response_scene_generation != out->request_scene_generation
        || out->response_window != out->request_window
        || out->response_object != out->request_object
        || out->response_object_aux != out->request_object_aux) {
        return kNowSemanticCopyMismatch;
    }
    if (out->response_status < kNowPeekSemanticStatusOk
        || out->response_status > kNowPeekSemanticStatusStale
        || out->response_record_count > kNowPeekSemanticMaxRecords
        || out->response_record_count > out->response_total_count) {
        return kNowSemanticCopyMalformed;
    }
    if ((NowPeekU32)(ticks - out->response_served_ticks)
            > (NowPeekU32)kNowPeekSemanticLeaseTicks) {
        return kNowSemanticCopyStale;
    }
    for (i = 0; i < out->response_record_count; ++i) {
        if (!record_shape_ok(&out->records[i], out->request_op)) {
            return kNowSemanticCopyMalformed;
        }
    }
    return kNowSemanticCopyOk;
}

int now_semantic_batch_ready(volatile const NowPeekTable *table)
{
    unsigned long need;

    /* The first cell's readiness is a precondition, not a duplicate
       check: the batch cell is P2's second cell and is armed by the same
       capability bit. What is asked additionally is the accretive pair -
       the table reaches this far, and the format word beside the cell
       claims it. */
    if (!now_semantic_table_ready(table)) {
        return 0;
    }
    need = (unsigned long)offsetof(NowPeekTable, semantic_batch)
         + (unsigned long)sizeof(NowPeekSemanticBatchCell);
    return table->length >= need
        && table->semantic_batch_format == kNowPeekSemanticBatchFormatV1
        && table->semantic_batch_length == sizeof(NowPeekSemanticBatchCell);
}

int now_semantic_batch_pending(volatile const NowPeekTable *table,
                               NowPeekU32 ticks)
{
    volatile const NowPeekSemanticBatchCell *cell;

    if (!now_semantic_batch_ready(table)
        || table->writer.resident_owner_epoch == 0) {
        return 0;
    }
    cell = &table->semantic_batch;
    return cell->request_generation != 0
        && cell->request_writer_epoch == table->writer.resident_owner_epoch
        && cell->response_request_generation != cell->request_generation
        && !expired(ticks, cell->request_deadline_ticks);
}

NowSemanticRequestVerdict now_semantic_batch_verdict(
    volatile const NowPeekTable *table, NowPeekU32 current_a5,
    NowPeekU32 ticks)
{
    volatile const NowPeekSemanticBatchCell *cell;

    if (!now_semantic_batch_ready(table)
        || (table->arm_active & kNowPeekTableCapTree) == 0) {
        return kNowSemanticNoPlane;
    }
    cell = &table->semantic_batch;
    /* There is no op field: this cell asks one question. The window is
       the subject and is therefore required, and a start ordinal beyond
       the walk's own ceiling could never name a control. */
    if (cell->request_generation == 0
        || cell->request_writer_epoch == 0
        || cell->request_writer_epoch != table->writer.resident_owner_epoch
        || cell->request_target_a5 == 0
        || cell->request_window == 0
        || cell->request_start >= kNowPeekSemanticBatchWalkMax) {
        return kNowSemanticBadRequest;
    }
    if (cell->request_target_a5 != current_a5) {
        return kNowSemanticWrongTarget;
    }
    if (expired(ticks, cell->request_deadline_ticks)) {
        return kNowSemanticStale;
    }
    return kNowSemanticAccept;
}

static int class_record_shape_ok(const NowPeekSemanticClassRecord *record)
{
    /* A record with no control names nothing, so it cannot be attached to
       anything - that is malformed rather than merely empty. */
    return record->control != 0
        && record->status >= kNowPeekSemanticStatusOk
        && record->status <= kNowPeekSemanticStatusStale
        && record->kind <= kNowPeekSemanticControlOtherSystem
        && record->text_copied <= kNowPeekSemanticTextMax
        && record->text_copied <= record->text_length
        && ((record->flags & kNowPeekSemanticRecordTextComplete) == 0
            || record->text_copied == record->text_length);
}

NowSemanticCopyVerdict now_semantic_batch_copy_response(
    volatile const NowPeekTable *table, NowPeekU32 ticks,
    NowPeekSemanticBatchCell *out)
{
    volatile const NowPeekSemanticBatchCell *cell;
    NowPeekU32 generation;
    unsigned int i, j;

    if (out == NULL || !now_semantic_batch_ready(table)) {
        return kNowSemanticCopyNoPlane;
    }
    cell = &table->semantic_batch;
    generation = cell->response_generation;
    if (generation == 0 || (generation & 1U) != 0) {
        return kNowSemanticCopyInProgress;
    }
    copy_from_resident(out, cell, sizeof(*out));
    if (cell->response_generation != generation
        || out->response_generation != generation) {
        return kNowSemanticCopyInProgress;
    }
    if (out->response_request_generation != out->request_generation
        || out->response_writer_epoch != out->request_writer_epoch
        || out->response_target_a5 != out->request_target_a5
        || out->response_scene_generation != out->request_scene_generation
        || out->response_window != out->request_window
        || out->response_start != out->request_start) {
        return kNowSemanticCopyMismatch;
    }
    if (out->response_status < kNowPeekSemanticStatusOk
        || out->response_status > kNowPeekSemanticStatusStale
        || out->response_record_count > kNowPeekSemanticMaxRecords
        || (NowPeekU32)out->response_start + out->response_record_count
               > out->response_total_count) {
        return kNowSemanticCopyMalformed;
    }
    for (i = 0; i < out->response_record_count; ++i) {
        if (!class_record_shape_ok(&out->records[i])) {
            return kNowSemanticCopyMalformed;
        }
        /* One reply must not name the same control twice. A duplicate
           would let one control's kind overwrite another's under a name
           they appear to share, and the join is by control word alone. */
        for (j = 0; j < i; ++j) {
            if (out->records[j].control == out->records[i].control) {
                return kNowSemanticCopyMalformed;
            }
        }
    }
    if ((NowPeekU32)(ticks - out->response_served_ticks)
            > (NowPeekU32)kNowPeekSemanticLeaseTicks) {
        return kNowSemanticCopyStale;
    }
    return kNowSemanticCopyOk;
}
