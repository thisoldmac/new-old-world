#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "now_semantic_logic.h"

typedef struct {
    int custom;
    int menu_rows;
} Fixture;

static int g_failures;

static void check(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        ++g_failures;
    }
}

static NowPeekU32 classify_control(void *context,
                                   NowPeekU32 window,
                                   NowPeekU32 control,
                                   NowPeekU16 *kind)
{
    Fixture *fixture = (Fixture *)context;

    if (window != 0x20 || control != 0x30)
        return kNowPeekSemanticStatusWrongTarget;
    *kind = fixture->custom ? kNowPeekSemanticControlCustom
                            : kNowPeekSemanticControlStandard;
    return fixture->custom ? kNowPeekSemanticStatusUnsupportedCustom
                           : kNowPeekSemanticStatusOk;
}

static NowPeekU32 list_bounds(void *context,
                              NowPeekU32 window,
                              NowPeekU32 control,
                              NowPeekU16 *rows,
                              NowPeekU16 *columns)
{
    NowPeekU16 kind;
    NowPeekU32 status = classify_control(context, window, control, &kind);

    if (status != kNowPeekSemanticStatusOk) return status;
    *rows = 2;
    *columns = 2;
    return status;
}

static NowPeekU32 list_cell(void *context,
                            NowPeekU32 control,
                            NowPeekU16 row,
                            NowPeekU16 column,
                            unsigned char *text,
                            NowPeekU16 capacity,
                            NowPeekU16 *length,
                            NowPeekU32 *flags)
{
    static const char *const names[] = {
        "New York", "Rome", "Tokyo", "Tomorrow"
    };
    const char *value = names[row * 2 + column];
    NowPeekU16 copied;

    (void)context;
    (void)control;
    *length = (NowPeekU16)strlen(value);
    copied = *length < capacity ? *length : capacity;
    memcpy(text, value, copied);
    if (row == 0 && column == 1) *flags |= kNowPeekSemanticRecordSelected;
    return kNowPeekSemanticStatusOk;
}

static NowPeekU32 menu_count(void *context,
                             NowPeekU32 menu,
                             NowPeekI32 menu_id,
                             NowPeekU16 *count)
{
    Fixture *fixture = (Fixture *)context;

    if (menu != 0x40 || menu_id != 128)
        return kNowPeekSemanticStatusWrongTarget;
    *count = (NowPeekU16)fixture->menu_rows;
    return kNowPeekSemanticStatusOk;
}

static NowPeekU32 menu_item(void *context,
                            NowPeekU32 menu,
                            NowPeekU16 index,
                            unsigned char *text,
                            NowPeekU16 capacity,
                            NowPeekU16 *length,
                            NowPeekU32 *flags)
{
    char value[20];
    NowPeekU16 copied;

    (void)context;
    (void)menu;
    sprintf(value, "Desk Accessory %u", index);
    *length = (NowPeekU16)strlen(value);
    copied = *length < capacity ? *length : capacity;
    memcpy(text, value, copied);
    *flags = kNowPeekSemanticRecordEnabled;
    return kNowPeekSemanticStatusOk;
}

static void make_request(NowPeekSemanticCell *cell, NowPeekU32 operation)
{
    memset(cell, 0, sizeof(*cell));
    cell->request_generation = 3;
    cell->request_op = operation;
    cell->request_writer_epoch = 7;
    cell->request_target_a5 = 0x10;
    cell->request_scene_generation = 9;
    cell->request_window = 0x20;
    cell->request_object = operation == kNowPeekSemanticOpSystemMenu
                               ? 0x40
                               : 0x30;
    cell->request_object_aux = operation == kNowPeekSemanticOpSystemMenu
                                   ? 128
                                   : 0;
}

int main(void)
{
    Fixture fixture = {0, 18};
    NowSemanticSource source = {
        &fixture,
        classify_control,
        list_bounds,
        list_cell,
        menu_count,
        menu_item
    };
    NowPeekSemanticCell cell;

    make_request(&cell, kNowPeekSemanticOpListCells);
    now_semantic_resolve(&cell, 100, &source);
    check(cell.response_generation != 0 &&
              !(cell.response_generation & 1),
          "publish commits even");
    check(cell.response_status == kNowPeekSemanticStatusOk &&
              cell.response_record_count == 4,
          "Date & Time list-shaped fixture");
    check(cell.records[1].flags & kNowPeekSemanticRecordSelected,
          "selection carried");

    fixture.custom = 1;
    make_request(&cell, kNowPeekSemanticOpControlClass);
    now_semantic_resolve(&cell, 101, &source);
    check(cell.response_status == kNowPeekSemanticStatusUnsupportedCustom &&
              cell.records[0].aux == kNowPeekSemanticControlCustom,
          "custom control remains explicit");

    fixture.custom = 0;
    make_request(&cell, kNowPeekSemanticOpSystemMenu);
    now_semantic_resolve(&cell, 102, &source);
    check(cell.response_record_count == 18 && cell.response_total_count == 18,
          "Finder Apple fixture exceeds old 12-row bound");

    fixture.menu_rows = 33;
    make_request(&cell, kNowPeekSemanticOpSystemMenu);
    now_semantic_resolve(&cell, 103, &source);
    check(cell.response_status == kNowPeekSemanticStatusTruncated &&
              cell.response_record_count == 32 &&
              cell.response_total_count == 33,
          "overflow explicit and bounded");

    if (g_failures != 0) return EXIT_FAILURE;
    puts("now_semantic_logic: all checks passed");
    return 0;
}
