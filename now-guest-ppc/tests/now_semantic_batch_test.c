/* P2's second cell: the batched control-class resolver and its guard.
 *
 * The defect this cell exists to fix was a transport, not a classifier:
 * one request per scene, spent on whichever fact expired fastest, left
 * 121 of 122 controls in the ten-panel corpus with no kind at all. So
 * the properties worth pinning here are the ones that decide whether a
 * batch is honest rather than merely bigger:
 *
 *   - ONE walk serves the whole reply (the cost argument for batching);
 *   - a record names its control, so a reply cannot be joined by
 *     traversal order;
 *   - one control's refusal is not the batch's refusal;
 *   - a window larger than one reply is drained by resuming, not
 *     silently truncated;
 *   - the guard refuses a reply that names one control twice, echoes a
 *     different identity, or was published half-written.
 *
 * Run by scripts/test-native (which is where its cc line lives).
 */
#include <stdio.h>
#include <string.h>

#include "now_semantic_guard.h"
#include "now_semantic_logic.h"

typedef struct {
    NowPeekU32 controls[kNowPeekSemanticBatchWalkMax];
    NowPeekU16 count;
    NowPeekU32 window;
    int walks;          /* how many times the hierarchy was enumerated */
    int classifies;     /* how many controls were typed */
    NowPeekU32 custom;  /* this control refuses classification */
    NowPeekU32 texted;  /* this control returns a displayed value */
    NowPeekU16 text_len_override;
} Fixture;

static int g_failures;

static void check(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        ++g_failures;
    }
}

static NowPeekU16 collect(void *ctx, NowPeekU32 window, NowPeekU32 *out,
                          NowPeekU16 cap)
{
    Fixture *f = (Fixture *)ctx;
    NowPeekU16 i;

    ++f->walks;
    if (window != f->window) return 0;
    for (i = 0; i < f->count && i < cap; ++i) out[i] = f->controls[i];
    return i;
}

static NowPeekU32 classify_member(void *ctx, NowPeekU32 window,
                                  NowPeekU32 control, NowPeekU16 *kind,
                                  unsigned char *text, NowPeekU16 cap,
                                  NowPeekU16 *true_length, NowPeekU32 *flags)
{
    Fixture *f = (Fixture *)ctx;
    const char *value = "8/4/2026";
    NowPeekU16 len;

    (void)window;
    ++f->classifies;
    *true_length = 0;
    *flags = 0;
    if (control == f->custom) {
        *kind = kNowPeekSemanticControlCustom;
        return kNowPeekSemanticStatusUnsupportedCustom;
    }
    if (control == f->texted) {
        *kind = kNowPeekSemanticControlClock;
        len = f->text_len_override != 0
            ? f->text_len_override : (NowPeekU16)strlen(value);
        *true_length = len;
        memcpy(text, value, len < cap ? len : cap);
        return kNowPeekSemanticStatusOk;
    }
    *kind = kNowPeekSemanticControlPushButton;
    return kNowPeekSemanticStatusOk;
}

static void fixture_init(Fixture *f, NowPeekU16 count)
{
    NowPeekU16 i;

    memset(f, 0, sizeof(*f));
    f->window = 0x2000;
    f->count = count;
    /* Deliberately non-contiguous and not in ordinal order: a join that
       secretly used the ordinal would still pass against 1,2,3. */
    for (i = 0; i < count; ++i) f->controls[i] = 0x9000u + (i * 0x40u);
}

static void request(NowPeekSemanticBatchCell *cell, NowPeekU32 window,
                    NowPeekU32 start)
{
    memset(cell, 0, sizeof(*cell));
    cell->request_generation = 7;
    cell->request_writer_epoch = 3;
    cell->request_target_a5 = 0x100;
    cell->request_scene_generation = 11;
    cell->request_window = window;
    cell->request_start = start;
    cell->request_deadline_ticks = 500;
}

/* A table whose length, format and arm bits make both P2 cells live. */
static void table_init(NowPeekTable *table)
{
    memset(table, 0, sizeof(*table));
    table->magic = (NowPeekU32)kNowPeekTableMagic;
    table->ext_major = kNowPeekExtMajor;
    table->length = sizeof(NowPeekTable);
    table->caps = kNowPeekTableCapTree;
    table->arm_active = kNowPeekTableCapTree;
    table->semantic_format = kNowPeekSemanticFormatV2;
    table->semantic_length = sizeof(NowPeekSemanticCell);
    table->semantic_batch_format = kNowPeekSemanticBatchFormatV1;
    table->semantic_batch_length = sizeof(NowPeekSemanticBatchCell);
    table->writer.resident_owner_epoch = 3;
}

static void test_one_walk_many_controls(void)
{
    Fixture f;
    NowPeekSemanticBatchCell cell;
    NowSemanticBatchSource source;
    NowPeekU16 i;

    fixture_init(&f, 12);
    f.custom = f.controls[4];
    request(&cell, f.window, 0);
    source.ctx = &f;
    source.collect = collect;
    source.classify_member = classify_member;
    now_semantic_batch_resolve(&cell, 100, &source);

    /* THE COST ARGUMENT. Twelve controls typed, one hierarchy walk. If
       this ever reads 12, the batch has stopped being cheaper per fact
       than the single-control op it replaced. */
    check(f.walks == 1, "one walk serves the whole reply");
    check(f.classifies == 12, "every collected control is classified");
    check(cell.response_record_count == 12, "twelve records");
    check(cell.response_total_count == 12, "total is the walk's count");
    check(cell.response_status == kNowPeekSemanticStatusOk, "batch ok");

    for (i = 0; i < 12; ++i) {
        check(cell.records[i].control == f.controls[i],
              "record names the control it describes");
    }
    /* One control refused; the batch did not. */
    check(cell.records[4].status == kNowPeekSemanticStatusUnsupportedCustom,
          "the custom control refuses in its own record");
    check(cell.records[4].kind == kNowPeekSemanticControlCustom,
          "the refusing record still carries its kind");
    check(cell.records[5].status == kNowPeekSemanticStatusOk,
          "a refusal does not stop the controls after it");
    check(cell.response_status == kNowPeekSemanticStatusOk,
          "one control's refusal is not the batch's");
}

static void test_resume_drains_a_large_window(void)
{
    Fixture f;
    NowPeekSemanticBatchCell cell;
    NowSemanticBatchSource source;
    NowPeekU16 first_count;

    fixture_init(&f, 40);   /* more than one reply carries */
    source.ctx = &f;
    source.collect = collect;
    source.classify_member = classify_member;

    request(&cell, f.window, 0);
    now_semantic_batch_resolve(&cell, 100, &source);
    check(cell.response_record_count == kNowPeekSemanticMaxRecords,
          "the first page fills the reply");
    check(cell.response_status == kNowPeekSemanticStatusTruncated,
          "an unfinished window says truncated");
    check(cell.response_total_count == 40,
          "truncation still reports the true total");
    first_count = cell.response_record_count;
    check(cell.records[first_count - 1].control == f.controls[31],
          "the page ends where the next one resumes");

    request(&cell, f.window, first_count);
    now_semantic_batch_resolve(&cell, 100, &source);
    check(cell.response_record_count == 8, "the second page carries the rest");
    check(cell.response_status == kNowPeekSemanticStatusOk,
          "the drained window is ok");
    check(cell.records[0].control == f.controls[32],
          "the second page starts at the requested ordinal");
    check(cell.response_start == first_count, "the reply echoes its start");
}

static void test_walk_ceiling_is_the_contract_number(void)
{
    Fixture f;
    NowPeekSemanticBatchCell cell;
    NowSemanticBatchSource source;

    /* The fixture offers exactly the ceiling; the resolver must not ask
       for more than its own array can hold. */
    fixture_init(&f, (NowPeekU16)kNowPeekSemanticBatchWalkMax);
    request(&cell, f.window, 0);
    source.ctx = &f;
    source.collect = collect;
    source.classify_member = classify_member;
    now_semantic_batch_resolve(&cell, 100, &source);
    check(cell.response_total_count == kNowPeekSemanticBatchWalkMax,
          "the walk ceiling is the largest total a window reports");
    check(cell.response_record_count == kNowPeekSemanticMaxRecords,
          "the reply is still bounded by its record count");
}

static void test_empty_and_overrun_start(void)
{
    Fixture f;
    NowPeekSemanticBatchCell cell;
    NowSemanticBatchSource source;

    fixture_init(&f, 3);
    source.ctx = &f;
    source.collect = collect;
    source.classify_member = classify_member;

    /* A window that is not the one walked yields nothing, honestly. */
    request(&cell, 0x7777, 0);
    now_semantic_batch_resolve(&cell, 100, &source);
    check(cell.response_record_count == 0, "an unknown window yields nothing");
    check(cell.response_status == kNowPeekSemanticStatusOk,
          "nothing found is not a failure");

    /* A resumed page the window has since shrunk past. */
    request(&cell, f.window, 10);
    now_semantic_batch_resolve(&cell, 100, &source);
    check(cell.response_record_count == 0, "a stale ordinal yields nothing");
    check(cell.response_total_count == 3, "and still reports the true total");
}

static void test_truncated_text_never_claims_complete(void)
{
    Fixture f;
    NowPeekSemanticBatchCell cell;
    NowSemanticBatchSource source;

    fixture_init(&f, 2);
    f.texted = f.controls[1];
    f.text_len_override = kNowPeekSemanticTextMax + 9;
    request(&cell, f.window, 0);
    source.ctx = &f;
    source.collect = collect;
    source.classify_member = classify_member;
    now_semantic_batch_resolve(&cell, 100, &source);

    check(cell.records[1].text_copied == kNowPeekSemanticTextMax,
          "a long value copies exactly the buffer");
    check(cell.records[1].text_length == kNowPeekSemanticTextMax + 9,
          "and reports its true length");
    check((cell.records[1].flags & kNowPeekSemanticRecordTextComplete) == 0,
          "a clipped value never claims to be complete");
    check(cell.records[1].status == kNowPeekSemanticStatusTruncated,
          "the clipped record says truncated");
}

static void test_refuse_publishes_a_committed_reply(void)
{
    NowPeekSemanticBatchCell cell;

    request(&cell, 0x2000, 0);
    now_semantic_batch_refuse(&cell, 100, kNowPeekSemanticStatusStale);
    check(cell.response_status == kNowPeekSemanticStatusStale,
          "the refusal carries its reason");
    check(cell.response_generation != 0
              && (cell.response_generation & 1U) == 0,
          "a refusal commits an even generation like any other reply");
    check(cell.response_request_generation == cell.request_generation,
          "and answers the generation that was asked");
}

static void test_guard_readiness_is_accretive(void)
{
    NowPeekTable table;

    table_init(&table);
    check(now_semantic_batch_ready(&table), "a full table serves both cells");

    /* A resident that predates the second cell: the first still works. */
    table.length = offsetof(NowPeekTable, semantic_batch);
    check(now_semantic_table_ready(&table), "the first cell survives");
    check(!now_semantic_batch_ready(&table),
          "a short table does not claim the second cell");

    table_init(&table);
    table.semantic_batch_format = kNowPeekSemanticBatchFormatNone;
    check(!now_semantic_batch_ready(&table),
          "an unclaimed format word is not a plane");

    table_init(&table);
    table.semantic_batch_length = sizeof(NowPeekSemanticBatchCell) - 4;
    check(!now_semantic_batch_ready(&table),
          "a disagreeing length word is not a plane");
}

static void test_guard_verdicts(void)
{
    NowPeekTable table;

    table_init(&table);
    request(&table.semantic_batch, 0x2000, 0);
    check(now_semantic_batch_verdict(&table, 0x100, 100) == kNowSemanticAccept,
          "an exact live request is accepted");
    check(now_semantic_batch_verdict(&table, 0x999, 100)
              == kNowSemanticWrongTarget,
          "another process must not serve this request");
    check(now_semantic_batch_verdict(&table, 0x100, 9000) == kNowSemanticStale,
          "an expired request is stale");

    request(&table.semantic_batch, 0, 0);
    check(now_semantic_batch_verdict(&table, 0x100, 100)
              == kNowSemanticBadRequest,
          "the window is the subject and is required");

    request(&table.semantic_batch, 0x2000, kNowPeekSemanticBatchWalkMax);
    check(now_semantic_batch_verdict(&table, 0x100, 100)
              == kNowSemanticBadRequest,
          "a start at the walk ceiling could name no control");

    request(&table.semantic_batch, 0x2000, 0);
    table.semantic_batch.request_writer_epoch = 4;
    check(now_semantic_batch_verdict(&table, 0x100, 100)
              == kNowSemanticBadRequest,
          "a request from a previous writer is refused");

    table_init(&table);
    request(&table.semantic_batch, 0x2000, 0);
    table.arm_active = 0;
    check(now_semantic_batch_verdict(&table, 0x100, 100)
              == kNowSemanticNoPlane,
          "a disarmed plane serves nothing");
}

/* Serve the request sitting in `table` from `f`, the way the resident
   does, so the copy tests read a genuinely published reply. */
static void serve(NowPeekTable *table, Fixture *f, NowPeekU32 ticks)
{
    NowSemanticBatchSource source;

    source.ctx = f;
    source.collect = collect;
    source.classify_member = classify_member;
    now_semantic_batch_resolve(&table->semantic_batch, ticks, &source);
}

static void test_guard_copy(void)
{
    NowPeekTable table;
    NowPeekSemanticBatchCell out;
    Fixture f;

    fixture_init(&f, 5);
    table_init(&table);
    request(&table.semantic_batch, f.window, 0);
    serve(&table, &f, 100);

    check(now_semantic_batch_copy_response(&table, 110, &out)
              == kNowSemanticCopyOk,
          "a committed fresh reply copies");
    check(out.response_record_count == 5, "and carries its records");
    check(out.records[2].control == f.controls[2],
          "the copy preserves each record's control");

    check(now_semantic_batch_copy_response(&table, 100000, &out)
              == kNowSemanticCopyStale,
          "a reply older than its lease is stale");

    /* Half-published: the resident is mid-write, generation is odd. */
    table.semantic_batch.response_generation |= 1U;
    check(now_semantic_batch_copy_response(&table, 110, &out)
              == kNowSemanticCopyInProgress,
          "an odd generation is never copied");

    /* An identity that drifted between request and reply. */
    table_init(&table);
    request(&table.semantic_batch, f.window, 0);
    serve(&table, &f, 100);
    table.semantic_batch.response_window = 0x4444;
    check(now_semantic_batch_copy_response(&table, 110, &out)
              == kNowSemanticCopyMismatch,
          "a reply that echoes another window is refused");

    /* THE DUPLICATE. Two records naming one control would let one kind
       overwrite another's under a name they appear to share, and the
       join is by control word alone. */
    table_init(&table);
    request(&table.semantic_batch, f.window, 0);
    serve(&table, &f, 100);
    table.semantic_batch.records[3].control =
        table.semantic_batch.records[1].control;
    check(now_semantic_batch_copy_response(&table, 110, &out)
              == kNowSemanticCopyMalformed,
          "one reply must not name the same control twice");

    /* A record that names nothing cannot be attached to anything. */
    table_init(&table);
    request(&table.semantic_batch, f.window, 0);
    serve(&table, &f, 100);
    table.semantic_batch.records[0].control = 0;
    check(now_semantic_batch_copy_response(&table, 110, &out)
              == kNowSemanticCopyMalformed,
          "a record naming no control is malformed");

    /* Text that claims completeness it does not have. */
    table_init(&table);
    request(&table.semantic_batch, f.window, 0);
    serve(&table, &f, 100);
    table.semantic_batch.records[0].text_length = 20;
    table.semantic_batch.records[0].text_copied = 4;
    table.semantic_batch.records[0].flags |=
        kNowPeekSemanticRecordTextComplete;
    check(now_semantic_batch_copy_response(&table, 110, &out)
              == kNowSemanticCopyMalformed,
          "a clipped record claiming complete is malformed");

    /* A page whose records run past the total it reports. */
    table_init(&table);
    request(&table.semantic_batch, f.window, 0);
    serve(&table, &f, 100);
    table.semantic_batch.response_total_count = 2;
    check(now_semantic_batch_copy_response(&table, 110, &out)
              == kNowSemanticCopyMalformed,
          "records may not run past the reported total");
}

static void test_pending_tracks_one_lease(void)
{
    NowPeekTable table;
    Fixture f;

    fixture_init(&f, 3);
    table_init(&table);
    check(!now_semantic_batch_pending(&table, 100),
          "an untouched cell has nothing pending");

    request(&table.semantic_batch, f.window, 0);
    check(now_semantic_batch_pending(&table, 100),
          "an unanswered request is pending");
    check(now_semantic_batch_pending(&table, 9000) == 0,
          "an expired request is no longer pending");

    serve(&table, &f, 100);
    check(!now_semantic_batch_pending(&table, 110),
          "an answered request is not pending");
}

int main(void)
{
    test_one_walk_many_controls();
    test_resume_drains_a_large_window();
    test_walk_ceiling_is_the_contract_number();
    test_empty_and_overrun_start();
    test_truncated_text_never_claims_complete();
    test_refuse_publishes_a_committed_reply();
    test_guard_readiness_is_accretive();
    test_guard_verdicts();
    test_guard_copy();
    test_pending_tracks_one_lease();
    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
