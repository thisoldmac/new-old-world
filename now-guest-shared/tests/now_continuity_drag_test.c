/* The promise drag's state machine, watched without a Macintosh: the
   size line, the arm that ripens on an APPLIED button rather than on
   wire arrival, and the four ways a drag ends - one of which is the
   cancel path the slice-2 brief makes a first-class deliverable rather
   than an afterthought.

   The cap is PINNED here to an independent literal as well as exercised
   through the constant. That is deliberate and it is the second place
   on purpose: the number is a decision about how long a person's Finder
   may sit inside a drop, and moving it should cost a failing test and a
   conversation, not a one-character edit nobody reviews. */
#include <stdio.h>
#include <string.h>

#include "now_continuity_drag.h"

#define CHECK(value) do { if (!(value)) {                                \
    fprintf(stderr, "promise drag failed at line %d\n", __LINE__);       \
    return 1;                                                            \
} } while (0)

static NowContinuityOfferItem file_of(long data_size)
{
    NowContinuityOfferItem it;

    memset(&it, 0, sizeof it);
    strcpy(it.name, "Report");
    it.data_size = data_size;
    it.have_file_type = 1;
    memcpy(&it.file_type, "TEXT", 4);
    it.have_creator = 1;
    memcpy(&it.creator, "ttxt", 4);
    return it;
}

/* A live table holding `it` under epoch 9, generation 3. */
static void publish(NowContinuityOfferTable *table,
                    const NowContinuityOfferItem *it)
{
    now_continuity_offer_reset(table);
    now_continuity_offer_apply(table, 9, 3, it);
}

static int test_size_line(void)
{
    NowContinuityOfferItem it;

    /* The pin. An independent literal, not derived from the header. */
    CHECK(kNowContinuityDragPromiseCapBytes == 1048576L);

    it = file_of(1L);
    CHECK(now_continuity_drag_size_ok(&it));

    /* Exactly at the line is servable; one byte past is not. A cap that
       refused its own stated size would make the number in the header a
       different number from the one in force. */
    it = file_of(kNowContinuityDragPromiseCapBytes);
    CHECK(now_continuity_drag_size_ok(&it));
    it = file_of(kNowContinuityDragPromiseCapBytes + 1L);
    CHECK(!now_continuity_drag_size_ok(&it));

    /* BOTH FORKS, SUMMED. A data fork under the line and a resource
       fork that pushes the pair over is the case a data-only check
       passes and the nested promise then sits through twice the bytes
       it agreed to. */
    it = file_of(kNowContinuityDragPromiseCapBytes - 100L);
    it.have_resource_size = 1;
    it.resource_size = 99L;
    CHECK(now_continuity_drag_size_ok(&it));
    it.resource_size = 101L;
    CHECK(!now_continuity_drag_size_ok(&it));

    /* A resource size the host never measured is not an unknown to
       refuse on: have_resource_size clear means it did not look, and
       refusing there would refuse every plain data file. */
    it = file_of(4096L);
    it.have_resource_size = 0;
    it.resource_size = kNowContinuityDragPromiseCapBytes * 4L;
    CHECK(now_continuity_drag_size_ok(&it));

    /* A negative size is nonsense on the wire and is not servable. */
    it = file_of(-1L);
    CHECK(!now_continuity_drag_size_ok(&it));

    CHECK(!now_continuity_drag_size_ok((const NowContinuityOfferItem *)0));
    return 0;
}

static int test_refusals(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset(&st);

    /* No live epoch: nothing is being held out. */
    now_continuity_offer_reset(&table);
    CHECK(now_continuity_drag_request(&st, &table, 0, 100) == kNowDragNoOffer);
    CHECK(st.state == kNowDragIdle);

    /* An offer under an epoch that has moved on is closed, not present,
       and reads here as nothing to pick up. */
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 10, 100) == kNowDragNoOffer);

    /* A folder: the file lane serves one file. */
    it.is_folder = 1;
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 100) == kNowDragFolder);
    it.is_folder = 0;

    /* Over the line. */
    it.data_size = kNowContinuityDragPromiseCapBytes + 1L;
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 100) == kNowDragTooLarge);
    CHECK(st.state == kNowDragIdle);

    /* Every refusal so far left the state alone. */
    CHECK(st.epoch == 0);
    return 0;
}

static int test_arm_ripens_on_applied_button(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset(&st);
    publish(&table, &it);

    CHECK(now_continuity_drag_request(&st, &table, 9, 1000) == kNowDragOK);
    CHECK(st.state == kNowDragWaitingButton);
    CHECK(st.epoch == 9 && st.generation == 3);
    /* The identity is a COPY. The host may rewrite its table the
       instant after; the drag promises what was picked up. */
    CHECK(strcmp(st.item.name, "Report") == 0);
    now_continuity_offer_reset(&table);
    CHECK(strcmp(st.item.name, "Report") == 0);

    /* WIRE ARRIVAL IS NOT A START. The request is in; with the applied
       button still up, nothing starts, however many passes go by. */
    CHECK(now_continuity_drag_tick(&st, 0, 1000) == kNowDragTickWait);
    CHECK(now_continuity_drag_tick(&st, 0, 1060) == kNowDragTickWait);
    CHECK(st.state == kNowDragWaitingButton);

    /* The applied button ripens it. */
    CHECK(now_continuity_drag_tick(&st, 1, 1061) == kNowDragTickStart);
    CHECK(st.state == kNowDragTracking);
    /* And a tick after the start is inert - Start must fire once, or
       TrackDrag gets called on a drag already tracking. */
    CHECK(now_continuity_drag_tick(&st, 1, 1062) == kNowDragTickWait);

    /* A second arm while one is in flight is busy, and does not
       trample the identity the promise will materialise. */
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 1063) == kNowDragBusy);
    CHECK(st.state == kNowDragTracking);
    return 0;
}

static int test_arm_expires_by_name(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset(&st);
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 500) == kNowDragOK);

    /* One tick short of the window is still waiting. */
    CHECK(now_continuity_drag_tick(&st, 0,
                                   500 + kNowContinuityDragArmTicks - 1)
          == kNowDragTickWait);
    /* At the window it gives up, by name rather than by hanging. */
    CHECK(now_continuity_drag_tick(&st, 0, 500 + kNowContinuityDragArmTicks)
          == kNowDragTickExpire);
    CHECK(st.state == kNowDragIdle);
    CHECK(st.last_verdict == kNowDragButtonNeverCame);
    CHECK(strcmp(now_continuity_drag_code(st.last_verdict),
                 "button-never-came") == 0);

    /* A TickCount wrap must not expire an arm that was just placed. */
    now_continuity_drag_reset(&st);
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 0xFFFFFFF0UL)
          == kNowDragOK);
    CHECK(now_continuity_drag_tick(&st, 0, 0x00000005UL) == kNowDragTickWait);
    CHECK(st.state == kNowDragWaitingButton);
    return 0;
}

static int test_promise_settles(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset(&st);
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    CHECK(now_continuity_drag_tick(&st, 1, 11) == kNowDragTickStart);

    CHECK(now_continuity_drag_promise_begin(&st) == 1);
    CHECK(st.state == kNowDragPromising);
    CHECK(!now_continuity_drag_should_abort(&st));

    now_continuity_drag_promise_end(&st, 1);
    /* Back to Tracking, NOT Idle: TrackDrag has not returned and is the
       only thing that may declare the drag over. */
    CHECK(st.state == kNowDragTracking);

    CHECK(now_continuity_drag_ended(&st, 1, 1) == kNowDragOK);
    CHECK(st.state == kNowDragIdle);
    return 0;
}

static int test_promise_fails_midstream(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset(&st);
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    CHECK(now_continuity_drag_tick(&st, 1, 11) == kNowDragTickStart);
    CHECK(now_continuity_drag_promise_begin(&st) == 1);

    now_continuity_drag_promise_end(&st, 0);
    /* A promise that BEGAN and broke must never be reported as a
       receiver that stayed silent - they want different diagnosis. */
    CHECK(now_continuity_drag_ended(&st, 1, 1) == kNowDragTransferFailed);
    CHECK(strcmp(now_continuity_drag_code(st.last_verdict),
                 "transfer-failed") == 0);
    CHECK(st.state == kNowDragIdle);
    return 0;
}

static int test_drop_never_asked(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset(&st);
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    CHECK(now_continuity_drag_tick(&st, 1, 11) == kNowDragTickStart);

    /* TrackDrag returns fine and the promise was never asked for: a
       receiver that does not speak promised HFS, named as itself. */
    CHECK(now_continuity_drag_ended(&st, 1, 1) == kNowDragPromiseNeverAsked);
    CHECK(st.state == kNowDragIdle);
    return 0;
}

/* THE CANCEL PATH. Classic Finder is unforgiving of a drag that never
   ends, so every way out of one is exercised here. */
static int test_cancel_before_button(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset(&st);
    CHECK(now_continuity_drag_cancel(&st) == kNowDragNotDragging);

    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    /* Before the button ripens this side still owns the loop, so a
       cancel ends it outright rather than leaving a flag set. */
    CHECK(now_continuity_drag_cancel(&st) == kNowDragOK);
    CHECK(st.state == kNowDragIdle);
    CHECK(st.last_verdict == kNowDragCancelled);
    CHECK(!st.cancel_requested);

    /* And a ripening tick afterwards cannot resurrect it. */
    CHECK(now_continuity_drag_tick(&st, 1, 11) == kNowDragTickWait);
    CHECK(st.state == kNowDragIdle);
    return 0;
}

static int test_cancel_during_track(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset(&st);
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    CHECK(now_continuity_drag_tick(&st, 1, 11) == kNowDragTickStart);

    /* Once the Drag Manager owns the loop a cancel can only ask. */
    CHECK(now_continuity_drag_cancel(&st) == kNowDragOK);
    CHECK(st.state == kNowDragTracking);
    CHECK(now_continuity_drag_should_abort(&st));

    /* A promise asked for after the cancel is REFUSED rather than
       streamed: the alternative is pulling a file nobody is still
       asking for. */
    CHECK(now_continuity_drag_promise_begin(&st) == 0);
    CHECK(st.state == kNowDragTracking);

    CHECK(now_continuity_drag_ended(&st, 1, 1) == kNowDragCancelled);
    CHECK(st.state == kNowDragIdle);
    /* The flag does not survive into the next drag. */
    CHECK(!st.cancel_requested);
    return 0;
}

static int test_cancel_mid_stream(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset(&st);
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    CHECK(now_continuity_drag_tick(&st, 1, 11) == kNowDragTickStart);
    CHECK(now_continuity_drag_promise_begin(&st) == 1);

    /* The only way into a nested Toolbox loop from outside it: the
       streaming pump reads this each pass. */
    CHECK(!now_continuity_drag_should_abort(&st));
    CHECK(now_continuity_drag_cancel(&st) == kNowDragOK);
    CHECK(now_continuity_drag_should_abort(&st));
    CHECK(st.state == kNowDragPromising);

    now_continuity_drag_promise_end(&st, 0);
    CHECK(now_continuity_drag_ended(&st, 1, 1) == kNowDragCancelled);
    return 0;
}

static int test_escape_declined_drop(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset(&st);
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    CHECK(now_continuity_drag_tick(&st, 1, 11) == kNowDragTickStart);

    /* Escape, or a drop nothing accepted: TrackDrag comes back with a
       failure and the drag is over, cleanly and by name. */
    CHECK(now_continuity_drag_ended(&st, 0, 1) == kNowDragCancelled);
    CHECK(st.state == kNowDragIdle);

    /* Ending twice is inert, not a second verdict. */
    CHECK(now_continuity_drag_ended(&st, 0, 1) == kNowDragNotDragging);
    return 0;
}

/* THE VERDICT THAT SEPARATES THREE DEFECTS THAT WORE ONE WORD.
   The first live guest run of this slice logged `cancelled (TrackDrag
   -128)` and that single word covered: a person letting go, the Finder
   declining the drop, and TrackDrag never having had a button to track.
   The applied button the arm ripens on is the resident's shared cell;
   the button TrackDrag tracks is this machine's own Button(). Asking
   both, separately, is the whole of the distinction. */
static int test_button_that_was_never_the_machines(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset(&st);
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    CHECK(now_continuity_drag_tick(&st, 1, 11) == kNowDragTickStart);

    /* No drop, and the machine's own button was UP when tracking began.
       The arm ripened on the plane's applied button, so this is exactly
       the case the live run could not attribute. */
    CHECK(now_continuity_drag_ended(&st, 0, 0) == kNowDragButtonNotReal);
    CHECK(st.state == kNowDragIdle);
    CHECK(st.last_verdict == kNowDragButtonNotReal);

    /* THE OTHER HALF OF THE PAIR, and the reason this is not just a
       renaming of `cancelled`: same failed TrackDrag, real button, and
       the verdict must go back to `cancelled`. A guard that only checked
       the first half would pass against an implementation that answered
       button-not-real unconditionally. */
    now_continuity_drag_reset(&st);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    CHECK(now_continuity_drag_tick(&st, 1, 11) == kNowDragTickStart);
    CHECK(now_continuity_drag_ended(&st, 0, 1) == kNowDragCancelled);

    /* AND THE THREE THAT OUTRANK IT. Each of these knows something
       happened, and the state of a button before it is not evidence
       against that knowledge - so an up button must NOT overwrite any of
       them. Ranked wrong, this verdict would swallow a settled promise,
       a cancel we asked for, and a stream that broke. */
    now_continuity_drag_reset(&st);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    CHECK(now_continuity_drag_tick(&st, 1, 11) == kNowDragTickStart);
    CHECK(now_continuity_drag_promise_begin(&st) == 1);
    now_continuity_drag_promise_end(&st, 1);
    CHECK(now_continuity_drag_ended(&st, 0, 0) == kNowDragOK);

    now_continuity_drag_reset(&st);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    CHECK(now_continuity_drag_tick(&st, 1, 11) == kNowDragTickStart);
    CHECK(now_continuity_drag_cancel(&st) == kNowDragOK);
    CHECK(now_continuity_drag_ended(&st, 0, 0) == kNowDragCancelled);

    now_continuity_drag_reset(&st);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    CHECK(now_continuity_drag_tick(&st, 1, 11) == kNowDragTickStart);
    CHECK(now_continuity_drag_promise_begin(&st) == 1);
    now_continuity_drag_promise_end(&st, 0);
    CHECK(now_continuity_drag_ended(&st, 0, 0) == kNowDragTransferFailed);

    /* The word itself, because a refusal a person reads and a test
       matches is the same string. */
    CHECK(strcmp(now_continuity_drag_code(kNowDragButtonNotReal),
                 "button-not-real") == 0);
    return 0;
}

static int test_start_failed(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset(&st);
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    CHECK(now_continuity_drag_tick(&st, 1, 11) == kNowDragTickStart);

    now_continuity_drag_start_failed(&st);
    CHECK(st.state == kNowDragIdle);
    CHECK(strcmp(now_continuity_drag_code(st.last_verdict),
                 "drag-failed") == 0);
    /* And the machine takes a fresh arm afterwards. */
    CHECK(now_continuity_drag_request(&st, &table, 9, 12) == kNowDragOK);
    return 0;
}

static int test_forget(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    /* A link that goes away while merely armed ends the arm. */
    now_continuity_drag_reset(&st);
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    now_continuity_drag_forget(&st);
    CHECK(st.state == kNowDragIdle);

    /* A link that goes away MID-DRAG may only ask: wiping the state
       would leave the promise callback reading a cleared identity
       mid-stream, and the Drag Manager still holding the loop. */
    now_continuity_drag_reset(&st);
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    CHECK(now_continuity_drag_tick(&st, 1, 11) == kNowDragTickStart);
    now_continuity_drag_forget(&st);
    CHECK(st.state == kNowDragTracking);
    CHECK(now_continuity_drag_should_abort(&st));
    CHECK(strcmp(st.item.name, "Report") == 0);
    return 0;
}

static int test_vocabulary(void)
{
    /* Every verdict has a word, and no two share one - a refusal a
       person reads and a test matches. */
    static const int verdicts[] = {
        kNowDragOK, kNowDragNoOffer, kNowDragFolder, kNowDragTooLarge,
        kNowDragBusy, kNowDragButtonNeverCame, kNowDragDragFailed,
        kNowDragTransferFailed, kNowDragCancelled, kNowDragNotDragging,
        kNowDragPromiseNeverAsked, kNowDragButtonNotReal, kNowDragBadEpoch
    };
    int i, j;
    int n = (int)(sizeof verdicts / sizeof verdicts[0]);

    for (i = 0; i < n; ++i) {
        const char *a = now_continuity_drag_code(verdicts[i]);
        CHECK(a != NULL && a[0] != '\0');
        CHECK(strcmp(a, "unknown") != 0);
        for (j = i + 1; j < n; ++j) {
            CHECK(strcmp(a, now_continuity_drag_code(verdicts[j])) != 0);
        }
    }
    CHECK(strcmp(now_continuity_drag_code(999), "unknown") == 0);

    CHECK(strcmp(now_continuity_drag_state_name(kNowDragIdle), "idle") == 0);
    CHECK(strcmp(now_continuity_drag_state_name(kNowDragWaitingButton),
                 "waiting-button") == 0);
    CHECK(strcmp(now_continuity_drag_state_name(kNowDragTracking),
                 "tracking") == 0);
    CHECK(strcmp(now_continuity_drag_state_name(kNowDragPromising),
                 "promising") == 0);
    CHECK(strcmp(now_continuity_drag_state_name(42), "unknown") == 0);
    return 0;
}

static int test_null_is_inert(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset((NowContinuityDragState *)0);
    now_continuity_drag_forget((NowContinuityDragState *)0);
    now_continuity_drag_start_failed((NowContinuityDragState *)0);
    now_continuity_drag_promise_end((NowContinuityDragState *)0, 1);
    CHECK(now_continuity_drag_promise_begin((NowContinuityDragState *)0) == 0);
    CHECK(now_continuity_drag_ended((NowContinuityDragState *)0, 1, 1)
          == kNowDragNotDragging);
    CHECK(now_continuity_drag_cancel((NowContinuityDragState *)0)
          == kNowDragNotDragging);
    CHECK(!now_continuity_drag_should_abort((NowContinuityDragState *)0));
    CHECK(now_continuity_drag_tick((NowContinuityDragState *)0, 1, 0)
          == kNowDragTickWait);

    now_continuity_drag_reset(&st);
    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, (const NowContinuityOfferTable *)0,
                                      9, 10) == kNowDragNoOffer);
    CHECK(now_continuity_drag_request((NowContinuityDragState *)0, &table,
                                      9, 10) == kNowDragNoOffer);
    return 0;
}

/* THE EDGE HANDED OFF. continuity.hostDragBegin's decision half: it
   starts rather than arms, it refuses an epoch that is not the live one,
   and it carries the host's gesture id so one crossing has one number.

   The arm is the difference under test. A console `offer --drag` names
   an intention with no gesture behind it and must wait for the applied
   button; a hostDragBegin arrives BECAUSE a person's hand crossed the
   edge, so waiting would spend the beat where neither machine's drag
   exists drawing nothing. State goes straight to Tracking here, and
   these cases are what stops that from being quietly re-armed later. */
static int test_host_begin_starts_without_an_arm(void)
{
    NowContinuityDragState st;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset(&st);
    CHECK(now_continuity_drag_host_begin(&st, &it, 9, 9, 77) == kNowDragOK);
    CHECK(st.state == kNowDragTracking);
    CHECK(st.drag_seq == 77);
    CHECK(st.host_driven);
    CHECK(st.epoch == 9);
    /* No generation is minted; the bytes come from the host's own offer
       table for this epoch. A number here would be a second name for one
       item. */
    CHECK(st.generation == 0);
    CHECK(strcmp(st.item.name, "Report") == 0);

    /* And it is a real drag from the Drag Manager's point of view: the
       promise may be asked for, and TrackDrag's return settles it. */
    CHECK(now_continuity_drag_promise_begin(&st) == 1);
    now_continuity_drag_promise_end(&st, 1);
    CHECK(now_continuity_drag_ended(&st, 1, 1) == kNowDragOK);
    CHECK(st.state == kNowDragIdle);
    return 0;
}

static int test_host_begin_refusals(void)
{
    NowContinuityDragState st;
    NowContinuityOfferItem it = file_of(4096L);
    NowContinuityOfferItem big = file_of(kNowContinuityDragPromiseCapBytes + 1L);
    NowContinuityOfferItem folder = file_of(0L);

    folder.is_folder = 1;

    /* A dead epoch is its own word. Three shapes of it, because all
       three would otherwise enter TrackDrag with an input proc reading a
       cell nobody is writing. */
    now_continuity_drag_reset(&st);
    CHECK(now_continuity_drag_host_begin(&st, &it, 9, 10, 1)
          == kNowDragBadEpoch);
    CHECK(now_continuity_drag_host_begin(&st, &it, 0, 9, 1)
          == kNowDragBadEpoch);
    CHECK(now_continuity_drag_host_begin(&st, &it, 9, 0, 1)
          == kNowDragBadEpoch);
    CHECK(st.state == kNowDragIdle);

    CHECK(now_continuity_drag_host_begin(&st, &folder, 9, 9, 1)
          == kNowDragFolder);
    CHECK(now_continuity_drag_host_begin(&st, &big, 9, 9, 1)
          == kNowDragTooLarge);
    CHECK(st.state == kNowDragIdle);

    /* Busy is asked before anything else, and a refusal leaves the drag
       in flight — and its identity — untouched. */
    CHECK(now_continuity_drag_host_begin(&st, &it, 9, 9, 5) == kNowDragOK);
    CHECK(now_continuity_drag_host_begin(&st, &big, 9, 9, 6) == kNowDragBusy);
    CHECK(now_continuity_drag_host_begin(&st, &it, 3, 9, 6) == kNowDragBusy);
    CHECK(st.drag_seq == 5);
    CHECK(st.item.data_size == 4096L);

    CHECK(now_continuity_drag_host_begin((NowContinuityDragState *)0, &it,
                                         9, 9, 1) == kNowDragNoOffer);
    CHECK(now_continuity_drag_host_begin(&st, (const NowContinuityOfferItem *)0,
                                         9, 9, 1) == kNowDragNoOffer);
    return 0;
}

/* A console drag after a host drag must not inherit its gesture id. The
   state struct lives for the life of the application, and a stale
   dragSeq would join one crossing's log lines to another's. */
static int test_console_drag_carries_no_gesture(void)
{
    NowContinuityDragState st;
    NowContinuityOfferTable table;
    NowContinuityOfferItem it = file_of(4096L);

    now_continuity_drag_reset(&st);
    CHECK(now_continuity_drag_host_begin(&st, &it, 9, 9, 42) == kNowDragOK);
    CHECK(now_continuity_drag_ended(&st, 0, 1) == kNowDragCancelled);

    publish(&table, &it);
    CHECK(now_continuity_drag_request(&st, &table, 9, 10) == kNowDragOK);
    CHECK(st.drag_seq == 0);
    CHECK(!st.host_driven);
    return 0;
}

int main(void)
{
    if (test_size_line()) return 1;
    if (test_refusals()) return 1;
    if (test_arm_ripens_on_applied_button()) return 1;
    if (test_arm_expires_by_name()) return 1;
    if (test_promise_settles()) return 1;
    if (test_promise_fails_midstream()) return 1;
    if (test_drop_never_asked()) return 1;
    if (test_cancel_before_button()) return 1;
    if (test_cancel_during_track()) return 1;
    if (test_cancel_mid_stream()) return 1;
    if (test_escape_declined_drop()) return 1;
    if (test_button_that_was_never_the_machines()) return 1;
    if (test_start_failed()) return 1;
    if (test_forget()) return 1;
    if (test_vocabulary()) return 1;
    if (test_null_is_inert()) return 1;
    if (test_host_begin_starts_without_an_arm()) return 1;
    if (test_host_begin_refusals()) return 1;
    if (test_console_drag_carries_no_gesture()) return 1;

    printf("ok\n");
    return 0;
}
