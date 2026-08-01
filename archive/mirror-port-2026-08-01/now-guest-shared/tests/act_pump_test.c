/*
 * act_pump_test.c - the act plane's pump handshake (P4b), on a host
 * compiler.
 *
 *   cc -Wall -Wextra -Werror -DNOW_PEEK_TABLE_HOST -I ../../contract \
 *      -I ../src act_pump_test.c ../src/now_act_guard.c -o /tmp/t && /tmp/t
 *
 * WHY THIS IS SEPARATE from now_act_guard_test.c. That file pins the
 * GUARD - who a patch may answer for. This one pins the LIFECYCLE around
 * it: which process posts the click, what a ticket means, and when a
 * faceless background application with no window and no console decides
 * to quit itself. Those are the decisions of a process nobody can see
 * running, on a system with no memory protection, and the machine where
 * they run is not a machine anybody debugs on.
 *
 * WHAT IS NOT HERE, said plainly: now-pump/'s Toolbox code. PPostEvent,
 * the low-memory mouse writes, WaitNextEvent, the SIZE flags that keep
 * it out of the foreground - none of that can be compiled by a host cc
 * and none of it is tested anywhere. The split is deliberate (the pump
 * calls into this file for every decision it makes and makes none of its
 * own), but the honest statement is that a green run here says the
 * lifecycle logic is right and says NOTHING about whether a click was
 * delivered on a Macintosh.
 *
 * MUTATIONS WATCHED FAILING (2026-08-01), each reverted after:
 *   - now_act_pump_should_exit: drop the seen_session clause -> an
 *     orphan whose session died inside the grace window survives, which
 *     is the exact failure the heartbeat exists to prevent.
 *   - now_act_stamp_fresh: `age < window` -> `age <= window` at the
 *     boundary is what the freshness tests pin; the strict form fails
 *     the "exactly at the window" case.
 *   - now_act_stamp_fresh: treat stamp 0 as fresh -> a table nobody has
 *     ever beaten at reads as a live session and no pump ever exits.
 *   - now_act_pump_attach: drop the click_posted adoption -> a pump
 *     launched into a table with an old pending request posts a click
 *     at a coordinate from a session that has ended.
 *   - pump_table: accept act format V3 (the previous format, and the
 *     realistic mismatch) -> the appended region is read out of a block
 *     the resident half never agreed to publish.
 */

#include "now_act_guard.h"

#include <stdio.h>
#include <string.h>

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        g_failures++;
    }
}

static void check_long(long got, long want, const char *what)
{
    if (got != want) {
        fprintf(stderr, "FAIL: %s (got %ld, want %ld)\n", what, got, want);
        g_failures++;
    }
}

/* A table as a current extension publishes one. */
static void fresh_table(NowPeekTable *table)
{
    memset(table, 0, sizeof *table);
    table->magic = (NowPeekU32)kNowPeekTableMagic;
    table->ext_major = kNowPeekExtMajor;
    table->length = (NowPeekU32)sizeof *table;
    table->caps = kNowPeekTableCapAnchors | kNowPeekTableCapAct;
    table->act_format = kNowPeekActFormatV4;
    table->act_text_max = (NowPeekU16)kNowPeekActTextMax;
}

/* ---- the appended region's own gate ------------------------------------ */

static void test_pump_gate(void)
{
    NowPeekTable table;

    check(now_act_pump(NULL) == NULL, "no table has no pump cell");

    fresh_table(&table);
    check(now_act_pump(&table) == &table.act_pump,
          "a current extension publishes the pump cell");

    /* The stale-resident case, and it is the one that matters: an
       extension that predates P4b allocated a block that ends before
       these fields. Writing a click request into it would run off the
       end of a system-heap pointer. */
    table.length = (NowPeekU32)offsetof(NowPeekTable, act_pump);
    check(now_act_pump(&table) == NULL,
          "a block that stops before the pump region has no pump cell");
    table.length = (NowPeekU32)(sizeof table - 1);
    check(now_act_pump(&table) == NULL,
          "one byte short of the last counter is still short");

    /* V3 rather than V1, because V3 is the format this bump actually
       supersedes and the one a machine could really be carrying: an
       extension that knows the click split and has no pump cell. Its
       LENGTH says nothing - a V3 table published by a build of this
       header is full length, since the fields exist in the struct
       either way - so act_format's exact match is the only thing between
       a V3 resident and a click request written into a region it never
       agreed to. */
    fresh_table(&table);
    table.act_format = kNowPeekActFormatV3;
    check(now_act_pump(&table) == NULL,
          "a pre-pump (V3) format has no pump cell whatever its length says");

    fresh_table(&table);
    table.act_format = kNowPeekActFormatV1;
    check(now_act_pump(&table) == NULL,
          "and neither does the format the plane shipped with");

    fresh_table(&table);
    table.caps = kNowPeekTableCapAnchors;
    check(now_act_pump(&table) == NULL,
          "an extension shipping the plane dark has no pump cell");

    fresh_table(&table);
    table.ext_major = kNowPeekExtMajor + 1;
    check(now_act_pump(&table) == NULL,
          "a different major is never partially trusted");
}

/* ---- freshness ---------------------------------------------------------- */

static void test_stamp_freshness(void)
{
    check_long(now_act_stamp_fresh(0, 100, 60), 0,
               "a stamp of zero is absent, never fresh");
    check_long(now_act_stamp_fresh(100, 100, 60), 1,
               "a stamp written this instant is fresh");
    check_long(now_act_stamp_fresh(100, 160, 60), 1,
               "exactly at the window is still fresh");
    check_long(now_act_stamp_fresh(100, 161, 60), 0,
               "one tick past the window is stale");

    /* TickCount is 32 bits and wraps. Unsigned subtraction carries the
       wrap correctly, so a beat written just before it stays fresh just
       after - the alternative is a pump that exits every time the
       counter turns over. */
    check_long(now_act_stamp_fresh(0xFFFFFFF0UL, 0x00000005UL, 60), 1,
               "a beat that straddles the 32-bit wrap is fresh");
    /* A stamp in the FUTURE subtracts to an enormous difference and
       reads stale. That is the safe direction: the pump exits, the route
       falls back inline, and the next beat repairs both. */
    check_long(now_act_stamp_fresh(500, 100, 60), 0,
               "a stamp from the future is stale, not fresh");
}

static void test_pump_and_session_alive(void)
{
    NowPeekTable table;
    NowPeekActPump *pump;

    fresh_table(&table);
    pump = now_act_pump(&table);

    check_long(now_act_pump_alive(pump, 1000), 0,
               "a table no pump has ever attached to has no live pump");
    check_long(now_act_session_alive(pump, 1000), 0,
               "a table with no session heartbeat has no live session");

    now_act_pump_attach(pump, 1000);
    check_long(now_act_pump_alive(pump, 1000), 1, "an attached pump is alive");
    check_long(now_act_pump_alive(pump, 1000 + kNowPeekActPumpTicks), 1,
               "a pump at the edge of its window is alive");
    check_long(now_act_pump_alive(pump, 1000 + kNowPeekActPumpTicks + 1), 0,
               "a pump that stopped beating is not alive");

    /* A crashed pump leaves Running behind a stale beat; a clean exit
       says Exiting. Both must read as absent, and the state word is what
       tells a human afterwards which one happened. */
    now_act_pump_detach(pump);
    check_long((long)pump->pump_state, (long)kNowPeekActPumpExiting,
               "a clean exit is recorded as such");
    check_long(now_act_pump_alive(pump, 1000), 0,
               "a pump on its way out is not alive");

    now_act_session_beat(pump, 2000);
    check_long(now_act_session_alive(pump, 2000), 1, "a beaten session is live");
    check_long(now_act_session_alive(pump, 2000 + kNowPeekActSessionTicks), 1,
               "a session at the edge of its window is live");
    check_long(now_act_session_alive(pump, 2000 + kNowPeekActSessionTicks + 1),
               0, "a session that stopped beating is not live");

    now_act_session_beat(pump, 0);
    check(pump->session_heartbeat != 0,
          "a beat on tick zero is not written as 'no session'");

    now_act_session_end(pump);
    check_long(now_act_session_alive(pump, 1), 0,
               "a closed session is not live");
}

/* ---- who posts the click ----------------------------------------------- */

static void test_click_route(void)
{
    NowPeekTable table;
    NowPeekActPump *pump;

    fresh_table(&table);
    pump = now_act_pump(&table);

    check_long(now_act_click_route(NULL, 500), kNowActClickInline,
               "with no pump cell the filter posts inline");
    check_long(now_act_click_route(pump, 500), kNowActClickInline,
               "with no pump running the filter posts inline");

    now_act_pump_attach(pump, 500);
    check_long(now_act_click_route(pump, 500), kNowActClickPump,
               "a live pump takes the click");
    check_long(now_act_click_route(pump, 500 + kNowPeekActPumpTicks + 1),
               kNowActClickInline,
               "a pump that died mid-session hands the route back");
}

/* ---- the ticket handshake ---------------------------------------------- */

static void test_click_handshake(void)
{
    NowPeekTable    table;
    NowPeekActPump *pump;
    NowActClickOrder order;
    unsigned long   ticket;

    fresh_table(&table);
    pump = now_act_pump(&table);
    now_act_pump_attach(pump, 100);

    memset(&order, 0, sizeof order);
    check_long(now_act_pump_click_due(pump, &order), 0,
               "an idle table has no click due");

    ticket = now_act_click_request(pump, 120, 45, 4096, 1);
    check(ticket != 0, "a request commits a ticket");
    check_long(now_act_click_state(pump, ticket), kNowActTicketWaiting,
               "a ticket nobody has served is waiting");

    check_long(now_act_pump_click_due(pump, &order), 1, "the pump sees the click");
    check_long((long)order.ticket, (long)ticket, "it carries the ticket");
    check_long(order.h, 120, "and the point the filter published");
    check_long(order.v, 45, "and the point the filter published (v)");
    check_long(order.mods, 4096, "and the modifiers");
    check_long(order.count, 1, "and the press count");

    now_act_pump_click_done(pump, ticket, kNowPeekActErrNone);
    check_long(now_act_click_state(pump, ticket), kNowActTicketPosted,
               "a served ticket reads posted");
    check_long(now_act_pump_click_due(pump, &order), 0,
               "and is not served twice");

    /* The queue can refuse. That is a DIFFERENT outcome from "armed and
       never taken" - nothing was asked of the application at all - and
       the application reads which it was from here. */
    ticket = now_act_click_request(pump, 10, 10, 0, 1);
    now_act_pump_click_done(pump, ticket, kNowPeekActErrPostFailed);
    check_long(now_act_click_state(pump, ticket), kNowActTicketRefused,
               "a refused queue is reported as refused, not as posted");
    /* The previous ticket must not read as posted once a newer one has
       been served: that is the whole reason this is a counter. */
    check_long(now_act_click_state(pump, ticket - 1), kNowActTicketWaiting,
               "an older ticket does not inherit a newer reply");

    check_long((long)now_act_click_request(NULL, 1, 1, 0, 1), 0,
               "a request against no pump cell commits nothing");
}

static void test_click_clamps_and_tearing(void)
{
    NowPeekTable    table;
    NowPeekActPump *pump;
    NowActClickOrder order;
    unsigned long   ticket;

    fresh_table(&table);
    pump = now_act_pump(&table);
    now_act_pump_attach(pump, 100);

    (void)now_act_click_request(pump, 0, 0, 0, 0);
    check_long((long)pump->click_count, 1, "a count below one is one press");
    (void)now_act_click_request(pump, 0, 0, 0, 99);
    check_long((long)pump->click_count, 3,
               "a count above three is three - single, double, triple");

    /* A count poked in out of range by anything but the request path is
       clamped on the READ as well. The two halves are compiled by
       different compilers into different processes; neither gets to
       assume the other's clamp ran. */
    ticket = now_act_click_request(pump, 5, 6, 0, 2);
    pump->click_count = 40;
    check_long(now_act_pump_click_due(pump, &order), 1, "still due");
    check_long(order.count, 3, "and clamped on the way out");
    check_long((long)order.ticket, (long)ticket, "with its own ticket");

    /* The settled path, and ONLY the settled path. now_act_pump_click_due
       re-reads the commit word after copying, so that a request the
       filter replaced mid-copy is dropped rather than half-served - and
       that re-read cannot be exercised from here, because nothing in a
       single-threaded test runs between the two reads. It is stated in
       the code and unproven by this file; the writer that could trigger
       it is a jGNE filter in another process. */
    pump->click_posted = pump->click_pending;   /* nothing outstanding */
    pump->click_h = 11;
    pump->click_v = 12;
    pump->click_pending = pump->click_posted + 1;
    check_long(now_act_pump_click_due(pump, &order), 1,
               "a settled request is taken");
    check_long(order.h, 11, "with its own point");
}

/* ---- the pump's own lifecycle ------------------------------------------ */

static void test_attach_does_not_replay(void)
{
    NowPeekTable    table;
    NowPeekActPump *pump;
    NowActClickOrder order;

    fresh_table(&table);
    pump = now_act_pump(&table);

    /* A request published while no pump existed. The filter posted it
       inline (or it was refused) long ago; a pump starting now has no
       business queueing a mouse click at that coordinate. */
    (void)now_act_click_request(pump, 300, 300, 0, 1);
    now_act_pump_attach(pump, 5000);
    check_long(now_act_pump_click_due(pump, &order), 0,
               "a pump adopts the backlog rather than replaying it");
}

static void test_pump_should_exit(void)
{
    NowPeekTable    table;
    NowPeekActPump *pump;
    unsigned long   started = 1000;

    fresh_table(&table);
    pump = now_act_pump(&table);

    check_long(now_act_pump_should_exit(NULL, 1000, started, 0), 1,
               "a pump with no table to serve exits");

    /* Launched, no beat yet. The application launches the pump, so it can
       easily be running first - inside the grace window that is normal. */
    check_long(now_act_pump_should_exit(pump, started, started, 0), 0,
               "a pump that has just started waits for its first beat");
    check_long(now_act_pump_should_exit(pump,
                                        started + kNowPeekActPumpGraceTicks,
                                        started, 0), 0,
               "and waits out the whole grace window");
    check_long(now_act_pump_should_exit(pump,
                                        started + kNowPeekActPumpGraceTicks + 1,
                                        started, 0), 1,
               "a pump nobody ever beat at is an orphan and goes");

    now_act_session_beat(pump, 2000);
    check_long(now_act_pump_should_exit(pump, 2000, started, 1), 0,
               "a live session keeps the pump");
    check_long(now_act_pump_should_exit(pump,
                                        2000 + kNowPeekActSessionTicks,
                                        started, 1), 0,
               "right up to the edge of the window");

    /* THE ORPHAN CASE, and the reason this clock exists at all: the host
       or the guest application died without asking the pump to quit.
       Note this fires INSIDE the grace window - a pump that has seen a
       session does not get the startup allowance again. */
    check_long(now_act_pump_should_exit(pump,
                                        2000 + kNowPeekActSessionTicks + 1,
                                        2000, 1), 1,
               "a session that stopped beating orphans the pump, which goes");

    now_act_session_end(pump);
    check_long(now_act_pump_should_exit(pump, 2100, started, 1), 1,
               "a session closed outright takes the pump with it");
}

/* ---- the verb patches' entry counters ---------------------------------- */

static void test_verb_trap_hits(void)
{
    NowPeekTable table;
    const unsigned long target = 0x00123456UL;
    const unsigned long other = 0x00999999UL;

    fresh_table(&table);

    /* Unconditional means unconditional: the plane is not armed, no
       request exists, and the count still moves. That is the fact "0/10
       menuact" could not establish - whether the patch was installed and
       entered at all. */
    now_act_verb_trap_hit(&table, kNowActVerbMenu, other);
    check_long((long)table.act_menu_hits, 1,
               "MenuSelect entries count with the plane idle");
    check_long((long)table.act_menu_hits_target, 0,
               "and no idle entry is scored against a request");

    table.act.op = kNowPeekActOpMenu;
    table.act.armed = kNowPeekActArmReady;
    table.act.target_a5 = (NowPeekU32)target;

    now_act_verb_trap_hit(&table, kNowActVerbMenu, other);
    check_long((long)table.act_menu_hits, 2, "another process's press counts");
    check_long((long)table.act_menu_hits_target, 0,
               "but not against our request - it was somebody else's A5");

    now_act_verb_trap_hit(&table, kNowActVerbMenu, target);
    check_long((long)table.act_menu_hits, 3, "our own press counts");
    check_long((long)table.act_menu_hits_target, 1, "and is scored to us");

    /* The control patch is a separate pair of words. A menu request must
       never move the control counters: they are read side by side and a
       shared counter would make both meaningless. */
    now_act_verb_trap_hit(&table, kNowActVerbControl, target);
    check_long((long)table.act_control_hits, 1, "TrackControl has its own");
    check_long((long)table.act_control_hits_target, 0,
               "and a menu request does not claim its entries");
    check_long((long)table.act_menu_hits, 3, "and does not move the menu's");

    table.act.op = kNowPeekActOpControl;
    now_act_verb_trap_hit(&table, kNowActVerbControl, target);
    check_long((long)table.act_control_hits_target, 1,
               "a control request scores its own trap");

    now_act_verb_trap_hit(&table, 7, target);
    check_long((long)table.act_menu_hits, 3, "an index nothing owns counts nothing");
    check_long((long)table.act_control_hits, 2, "for either word");

    now_act_verb_trap_hit(NULL, kNowActVerbMenu, target);

    /* A stale resident half has no room for these words. Nothing is
       written, and that is the same refusal the rest of the plane makes
       rather than a silent write past the end of a system-heap block. */
    table.length = (NowPeekU32)offsetof(NowPeekTable, act_pump);
    now_act_verb_trap_hit(&table, kNowActVerbMenu, target);
    check_long((long)table.act_menu_hits, 3,
               "a block with no room for the counters is not written to");
}

int main(void)
{
    test_pump_gate();
    test_stamp_freshness();
    test_pump_and_session_alive();
    test_click_route();
    test_click_handshake();
    test_click_clamps_and_tearing();
    test_attach_does_not_replay();
    test_pump_should_exit();
    test_verb_trap_hits();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("act_pump: ok\n");
    return 0;
}
