#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "now_semantic_guard.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

static void ready_table(NowPeekTable *table)
{
    NowPeekSemanticCell *cell;

    memset(table, 0, sizeof(*table));
    table->magic = (NowPeekU32)kNowPeekTableMagic;
    table->ext_major = kNowPeekExtMajor;
    table->length = sizeof(*table);
    table->caps = kNowPeekTableCapTree;
    table->arm_active = kNowPeekTableCapTree;
    table->semantic_format = kNowPeekSemanticFormatV2;
    table->semantic_length = sizeof(table->semantic);
    table->writer.resident_owner_epoch = 77;
    cell = &table->semantic;
    cell->request_generation = 9;
    cell->request_op = kNowPeekSemanticOpListCells;
    cell->request_writer_epoch = 77;
    cell->request_target_a5 = 0x10000;
    cell->request_scene_generation = 12;
    cell->request_window = 0x20000;
    cell->request_object = 0x30000;
    cell->request_object_aux = 4;
    cell->request_deadline_ticks = 1120;
}

static void committed_reply(NowPeekTable *table)
{
    NowPeekSemanticCell *cell = &table->semantic;
    NowPeekSemanticRecord *record = &cell->records[0];

    cell->response_generation = 10;
    cell->response_request_generation = cell->request_generation;
    cell->response_status = kNowPeekSemanticStatusOk;
    cell->response_writer_epoch = cell->request_writer_epoch;
    cell->response_target_a5 = cell->request_target_a5;
    cell->response_scene_generation = cell->request_scene_generation;
    cell->response_window = cell->request_window;
    cell->response_object = cell->request_object;
    cell->response_object_aux = cell->request_object_aux;
    cell->response_served_ticks = 1000;
    cell->response_record_count = 1;
    cell->response_total_count = 1;
    record->kind = kNowPeekSemanticRecordListCell;
    record->status = kNowPeekSemanticStatusOk;
    record->index = 1;
    record->aux = 0;
    record->flags = kNowPeekSemanticRecordSelected
                  | kNowPeekSemanticRecordTextComplete;
    record->text_length = 4;
    record->text_copied = 4;
    memcpy(record->text, "Rome", 4);
}

int main(void)
{
    NowPeekTable table;
    NowPeekSemanticCell copy;

    check(kNowPeekSemanticMaxRecords == 32,
          "P2 envelope covers the measured 16-row Finder Apple menu");
    check(kNowPeekSemanticFormatV2 == 2,
          "P2 v2 identifies typed control descriptions");
    check(sizeof(NowPeekSemanticRecord) == 48
              && kNowPeekSemanticTextMax == 32,
          "P2 record and text byte budgets stay frozen");
    ready_table(&table);
    check(now_semantic_table_ready(&table), "complete P2 table accepted");
    check(now_semantic_request_verdict(&table, 0x10000, 1000)
              == kNowSemanticAccept,
          "exact live target accepted");
    check(now_semantic_request_pending(&table, 1000),
          "unanswered request keeps its one-cell lease");
    check(!now_semantic_request_pending(&table, 1121),
          "expired request releases the one-cell lease");

    table.length = offsetof(NowPeekTable, semantic)
                 + sizeof(NowPeekSemanticCell) - 1;
    check(!now_semantic_table_ready(&table), "short resident refused");
    ready_table(&table);
    table.semantic.request_target_a5++;
    check(now_semantic_request_verdict(&table, 0x10000, 1000)
              == kNowSemanticWrongTarget,
          "wrong A5 refused");
    ready_table(&table);
    table.semantic.request_writer_epoch++;
    check(now_semantic_request_verdict(&table, 0x10000, 1000)
              == kNowSemanticBadRequest,
          "stale writer epoch refused");
    ready_table(&table);
    check(now_semantic_request_verdict(&table, 0x10000, 1121)
              == kNowSemanticStale,
          "expired request refused");

    ready_table(&table);
    committed_reply(&table);
    check(!now_semantic_request_pending(&table, 1000),
          "matching response releases the one-cell lease");
    check(now_semantic_copy_response(&table, 1120, &copy)
              == kNowSemanticCopyOk
              && copy.records[0].text_copied == 4
              && memcmp(copy.records[0].text, "Rome", 4) == 0,
          "matching committed response copied");
    table.semantic.response_generation = 11;
    check(now_semantic_copy_response(&table, 1120, &copy)
              == kNowSemanticCopyInProgress,
          "odd partial publish refused");

    ready_table(&table);
    committed_reply(&table);
    table.semantic.response_object++;
    check(now_semantic_copy_response(&table, 1120, &copy)
              == kNowSemanticCopyMismatch,
          "wrong object identity refused");
    committed_reply(&table);
    table.semantic.response_record_count = kNowPeekSemanticMaxRecords + 1;
    check(now_semantic_copy_response(&table, 1120, &copy)
              == kNowSemanticCopyMalformed,
          "record overflow refused");
    committed_reply(&table);
    table.semantic.records[0].kind = kNowPeekSemanticRecordControlClass;
    check(now_semantic_copy_response(&table, 1120, &copy)
              == kNowSemanticCopyMalformed,
          "wrong resolver record kind refused");
    committed_reply(&table);
    table.semantic.records[0].text_length = 33;
    table.semantic.records[0].text_copied = 32;
    check(now_semantic_copy_response(&table, 1120, &copy)
              == kNowSemanticCopyMalformed,
          "clipped text cannot claim complete");
    committed_reply(&table);
    check(now_semantic_copy_response(&table, 1121, &copy)
              == kNowSemanticCopyStale,
          "stale response refused");

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    puts("now_semantic_guard: all checks passed");
    return EXIT_SUCCESS;
}
