/* `actstate` - read the act plane's own instruments, as numbers.
   ------------------------------------------------------------------

   WHY A VERB RATHER THAN A BETTER ERROR SENTENCE. Every measurement this
   plane has produced so far has been read out of a FAILURE MESSAGE -
   "0/10 menuact", "the app never called FindWindow for our click" - and a
   sentence can only carry what its author thought to put in it. When the
   counters that would settle a question are not in the sentence, the run
   has to be done again; when they are, they are prose to be parsed. Both
   are how a measurement becomes an argument.

   So this verb reports the cell: the counters, the arm state, the click
   handshake and the route the plane would take right now, unconditionally
   and whether or not anything has been asked of it. A future
   before/after around an act reads them directly.

   IT DECIDES NOTHING, which is why it has no Toolbox-free half of its own
   the way `actselftest` does: every judgement in it - is the plane ready,
   is a pump alive, would a click go inline - is now_act_guard.c's, asked
   here and printed. A copy of any of those tests in this file would be a
   second answer to a question that has one.

   IT ALSO ARMS NOTHING. now_act_ready() would arm the plane as a side
   effect of asking whether it is there, and an instrument that changes
   the thing it measures is worse than no instrument: reading the state
   would install six trap patches in every process that pumps. This walks
   the table directly and reports whatever it finds, including "dark". */

#include <Carbon.h>
#include <stdio.h>
#include <string.h>

#include "mach_reply.h"
#include "mach_verbs.h"
#include "now_act_guard.h"
#include "peek.h"
#include "peek_table.h"

/* Ticks since a stamp, or -1 when the stamp has never been written. The
   distinction is the whole point of reporting it: 0 is "beating right
   now" and never-written is "nothing has ever done this", and a single
   number that meant both would say nothing at all. */
static long stamp_age(unsigned long stamp, unsigned long now)
{
    if (stamp == 0) {
        return -1;
    }
    return (long)(NowPeekU32)((NowPeekU32)now - (NowPeekU32)stamp);
}

/* One row, formatted. The value is built here rather than by each face,
   which is what keeps the two faces from disagreeing about a number. */
static void emit_f(NowActStateEmit emit, void *ctx, const char *label,
                   const char *fmt, unsigned long value)
{
    char text[64];

    snprintf(text, sizeof text, fmt, value);
    emit(ctx, label, text);
}

static void row_age(NowActStateEmit emit, void *ctx, const char *label,
                    unsigned long stamp, unsigned long now)
{
    long age = stamp_age(stamp, now);

    if (age < 0) {
        emit(ctx, label, "never");
        return;
    }
    emit_f(emit, ctx, label, "%lu ticks ago", (unsigned long)age);
}

static const char *plane_word(int state)
{
    switch (state) {
    case kNowActPlaneReady:       return "ready";
    case kNowActPlaneStale:       return "stale (the block has no room)";
    case kNowActPlaneWrongFormat: return "wrong format";
    case kNowActPlaneAbsent:      return "dark (this build ships it off)";
    default:                      return "no table";
    }
}

static const char *arm_word(unsigned long armed)
{
    switch (armed) {
    case kNowPeekActArmReady:  return "ready";
    case kNowPeekActArmStage2: return "stage 2";
    default:                   return "none";
    }
}

static const char *status_word(unsigned long status)
{
    switch (status) {
    case kNowPeekActStatusPending: return "pending";
    case kNowPeekActStatusDone:    return "done";
    case kNowPeekActStatusError:   return "error";
    default:                       return "idle";
    }
}

static const char *pump_word(unsigned long state)
{
    switch (state) {
    case kNowPeekActPumpRunning: return "running";
    case kNowPeekActPumpExiting: return "exiting";
    default:                     return "never attached";
    }
}

void now_mach_actstate_report(NowActStateEmit emit, void *ctx)
{
    const NowPeekTable *table = now_peek_table();
    NowPeekTable       *writable;
    const NowPeekActCell *cell;
    NowPeekActPump     *pump;
    unsigned long       now = (unsigned long)TickCount();
    int                 state;

    state = now_act_plane_state(table);
    emit(ctx, "Plane", plane_word(state));
    if (table == NULL) {
        emit(ctx, "Note",
                     "the NOW Extension is not installed on this Mac, so "
                     "there is no act plane to report on");
        return;
    }
    emit_f(emit, ctx, "Table length", "%lu bytes", (unsigned long)table->length);
    emit_f(emit, ctx, "Act format", "%lu", (unsigned long)table->act_format);
    emit_f(emit, ctx, "Armed planes", "0x%02lX", (unsigned long)table->arm_active);

    cell = &table->act;
    emit_f(emit, ctx, "Patches", "0x%02lX", (unsigned long)cell->patches);
    emit(ctx, "Armed", arm_word((unsigned long)cell->armed));
    emit(ctx, "Status", status_word((unsigned long)cell->status));
    emit_f(emit, ctx, "Op", "%lu", (unsigned long)cell->op);
    emit_f(emit, ctx, "Error", "%lu", (unsigned long)cell->error);
    emit_f(emit, ctx, "Fired", "%lu", (unsigned long)cell->fired);
    emit_f(emit, ctx, "Target A5", "0x%08lX", (unsigned long)cell->target_a5);
    emit_f(emit, ctx, "Served A5", "0x%08lX", (unsigned long)cell->served_a5);
    row_age(emit, ctx, "Served", (unsigned long)cell->served_ticks, now);

    /* The four window traps, then the two verb traps. Global and
       target-scoped side by side, always both: the global counter says
       the patch is installed and the system calls it, and only the pair
       says whether OUR request was the call that arrived. Either alone
       has been mistaken for the other in this plane already. */
    emit_f(emit, ctx, "FindWindow hits", "%lu", (unsigned long)cell->trap_hits[0]);
    emit_f(emit, ctx, "FindWindow ours", "%lu", (unsigned long)cell->trap_hits_target[0]);
    emit_f(emit, ctx, "GrowWindow hits", "%lu", (unsigned long)cell->trap_hits[1]);
    emit_f(emit, ctx, "GrowWindow ours", "%lu", (unsigned long)cell->trap_hits_target[1]);
    emit_f(emit, ctx, "TrackBox hits", "%lu", (unsigned long)cell->trap_hits[2]);
    emit_f(emit, ctx, "TrackBox ours", "%lu", (unsigned long)cell->trap_hits_target[2]);
    emit_f(emit, ctx, "TrackGoAway hits", "%lu", (unsigned long)cell->trap_hits[3]);
    emit_f(emit, ctx, "TrackGoAway ours", "%lu", (unsigned long)cell->trap_hits_target[3]);
    emit_f(emit, ctx, "FindWindow answers", "%lu", (unsigned long)cell->fw_answers);

    /* The CELL's own click ask (V3), which is a different reading from
       the pump's ticket below and is kept beside it rather than replaced
       by it. click_passes and click_last_a5 are what measured "every
       pass belonged to the target's own world" - the finding the pump
       exists to answer - so a run that still shows one world here is
       saying the pump is not being reached, which the pump's own rows
       cannot distinguish from a pump that never started. */
    emit_f(emit, ctx, "Click owed", "%lu", (unsigned long)cell->click_pending);
    emit_f(emit, ctx, "Click posted", "%lu", (unsigned long)cell->click_posted);
    emit_f(emit, ctx, "Click not-A5", "0x%08lX",
           (unsigned long)cell->click_not_a5);
    emit_f(emit, ctx, "Click passes", "%lu", (unsigned long)cell->click_passes);
    emit_f(emit, ctx, "Click last A5", "0x%08lX",
           (unsigned long)cell->click_last_a5);

    /* The pump region is gated separately from the cell (peek_table.h,
       P4b), so an extension that predates it reports every row above and
       none of the rows below - which is exactly the shape of that
       machine and is worth seeing rather than hiding behind a zero. */
    writable = (NowPeekTable *)table;
    pump = now_act_pump(writable);
    if (pump == NULL) {
        emit(ctx, "Pump region", "absent (this extension "
                                           "predates the act pump)");
        return;
    }
    emit_f(emit, ctx, "MenuSelect hits", "%lu", (unsigned long)writable->act_menu_hits);
    emit_f(emit, ctx, "MenuSelect ours", "%lu", (unsigned long)writable->act_menu_hits_target);
    emit_f(emit, ctx, "TrackControl hits", "%lu", (unsigned long)writable->act_control_hits);
    emit_f(emit, ctx, "TrackControl ours", "%lu", (unsigned long)writable->act_control_hits_target);

    emit(ctx, "Pump", pump_word((unsigned long)pump->pump_state));
    row_age(emit, ctx, "Pump beat", (unsigned long)pump->pump_heartbeat, now);
    row_age(emit, ctx, "Session beat", (unsigned long)pump->session_heartbeat,
            now);
    /* The one row a caller would otherwise have to derive - and deriving
       it means copying now_act_click_route's rule into whatever is
       reading, which is how two answers to one question start. */
    emit(ctx, "Click route",
                 now_act_click_route(pump, now) == kNowActClickPump
                     ? "the pump (its own classic context)"
                     : "V3 inline - the first jGNE pass outside the "
                       "target's world, which measured as never arriving");
    emit_f(emit, ctx, "Ticket asked", "%lu", (unsigned long)pump->click_pending);
    emit_f(emit, ctx, "Ticket served", "%lu", (unsigned long)pump->click_posted);
    emit_f(emit, ctx, "Last click error", "%lu", (unsigned long)pump->click_error);
    emit_f(emit, ctx, "Last click x", "%ld", (unsigned long)pump->click_h);
    emit_f(emit, ctx, "Last click y", "%ld", (unsigned long)pump->click_v);

}

/* The wire face: the same report, rendered into the command.result
   envelope every other command writes. */
static void wire_row(void *ctx, const char *label, const char *value)
{
    now_mach_row((NowMachRows *)ctx, label, value);
}

void now_mach_run_actstate(const char *request_json, long id,
                           char *out, long cap)
{
    static NowMachRows rows;            /* off the stack, like the plane's
                                           other verbs: 1 KB of rows is not
                                           a thing to put on a classic
                                           application's stack */

    (void)request_json;                 /* no arguments: it reports all of it */

    now_mach_rows_reset(&rows);
    now_mach_actstate_report(wire_row, &rows);
    now_mach_reply_rows(out, cap, id, "actstate", &rows);
}
