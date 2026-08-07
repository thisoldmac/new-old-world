#ifndef NOW_ACT_CLIENT_H
#define NOW_ACT_CLIENT_H

/* The act plane's application half: the Toolbox side of talking to the
   resident plane.

   THE SPLIT. act_args.c decides, and so does the reference layer
   this plane addresses through (src/observe/); now_act_guard.c (shared
   with the extension) decides; this file does the things only a
   Macintosh can do - Gestalt, the Process Manager, the event queue, and
   waiting. It is the layer with no native test, deliberately kept as
   thin as the job allows, for the same reason peek_read.c is thin.

   Nothing in here reaches into another process's memory. Foreign-memory
   READS live in the application (docs/resident-components.md) but they
   live in src/axwalk, behind a validated seam; this file only carries
   the request across and waits. */

#include <Carbon.h>

#include "axprocess.h"
#include "act_settlement.h"
#include "peek_table.h"

typedef enum {
    kNowActOk = 0,
    /* The extension is not installed, or is not one we trust at all. */
    kNowActNoExtension,
    /* Installed, and older than this plane: its table has no room for a
       request. REFUSED rather than written into - see now_act_plane_
       state(). A stale resident is a reboot; a silent unguarded patch is
       not something a caller can even see. */
    kNowActStaleExtension,
    /* Installed and current, but shipping the plane dark. */
    kNowActPlaneDark,
    /* No such process, or its partition cannot be bound. */
    kNowActNoTarget,
    /* Bound, but no anchor names its A5 world - the resting state for a
       process that has not pumped its event loop since the plane was
       armed. Not an error about the machine. */
    kNowActNoAnchor,
    /* The target never served the request: not pumping, or suspended. */
    kNowActTimeout,
    /* Served, but the plane did not arm - its patch is missing. */
    kNowActNotArmed,
    /* Armed, the click went, and the application never called the trap.
       The counters in the snapshot say which of the two failures it was. */
    kNowActNotTaken,
    /* The plane refused it and named why in the snapshot's `error`. */
    kNowActRefused,
    /* Another act already owns the single cell. Since 2026-08-06 the act
       wait pumps the wire, so a second act command CAN be dispatched
       into the middle of the first one - and this is the answer it gets.
       Refused, never queued: the caller would have had to wait out the
       first act's deadline anyway, and a caller told "busy" can decide
       while a caller made to wait cannot. now_act_inflight.h carries the
       whole argument, docs/no-hijack-criterion.md the trade. */
    kNowActBusy
} NowActStatus;

/* One bound target: the memory seam the walk needs, and the A5 world the
   request is addressed to.

   A5 rather than PSN, all the way down, because inside the resident hook
   the current A5 is one low-memory read while a PSN would need Process
   Manager calls that are not safe there. The mapping is ours to make and
   the anchor plane is what makes it. */
typedef struct {
    ProcessSerialNumber psn;
    NowAxContext        ax;
    unsigned long       a5;
    Str63               name;
} NowActTarget;

/* Is the plane usable, and arm it if so. Arming is idempotent and is
   what the extension watches; it is also the bypass switch, so the
   application owns turning the plane off. */
NowActStatus now_act_ready(void);

/* Disarm the whole plane. The immediate off switch: it does not wait for
   any process to pump, and it makes all six trap patches chain through. */
void now_act_shutdown(void);

/* Bind `psn` (NULL = the front process) to a target. */
NowActStatus now_act_open(const ProcessSerialNumber *psn, NowActTarget *out);

/* The request cell to fill in. NULL when the plane is not usable, AND
   NULL while another act already owns it - call now_act_why_no_cell() to
   tell those apart rather than assuming the first. Every act verb must
   go through this before it writes a field; that is where the one-act-
   at-a-time interlock lives (now_act_inflight.h). */
NowPeekActCell *now_act_cell(void);

/* Why now_act_cell() answered NULL: kNowActBusy when another act holds
   the cell, kNowActNoExtension otherwise. */
NowActStatus now_act_why_no_cell(void);

/* How many act commands this launch has refused as busy. Zero is the
   expected reading; a non-zero one means the wire really did dispatch an
   act into an armed window, which is the event the interlock exists for
   and the number worth reporting when it happens. */
unsigned long now_act_inflight_refused(void);

/* Post the filled-in cell and wait for the resident plane to serve it,
   then copy a seqlock-coherent snapshot out.

   YIELDS while waiting, and never spins. This is cooperative
   multitasking: a busy-wait holds the processor in THIS process, so the
   target never runs, never pumps, and never serves - the spin
   guarantees the timeout it is waiting through. WaitNextEvent with an
   event mask of ZERO is the documented way to give up the processor
   without dequeuing anything; stealing an event here would break the
   application we are driving.

   AND IT PUMPS THE WIRE while it waits (act_yield -> now_wire_pump),
   since 2026-08-06. It used to be on pump.h's "what cannot be pumped"
   list and that was wrong twice over: it CAN be pumped, and its stall
   was not human-scale - it ran the full deadline whenever a target
   declined, which lapsed the anchor plane's ten-second owner lease and
   made the next act fail. The price of pumping is that a second act
   command can now arrive mid-flight; it is refused kNowActBusy. Read
   act_yield's comment and docs/no-hijack-criterion.md before changing
   either half. */
NowActStatus now_act_submit(const NowActTarget *target,
                            NowPeekActCell *snapshot);

/* The latest normal-context scene generation available when a request is
   created. It is correlation evidence, not a resident safety authority. */
void now_act_note_scene_generation(unsigned long generation);
void now_act_observe_scene(const NowScene *scene);
const NowActSettlementRecord *now_act_last_settlement(void);

/* Arm the MENU MARK postcondition for the next act submitted, or clear
   it. Only the verb that has walked the menu knows whether the mark is
   meaningful there, so it decides; this file holds the cell and would
   otherwise have to re-derive what menuact already read. Cleared as the
   request is described, so an act that never reaches now_act_submit
   cannot leave a postcondition behind for the next one. */
void now_act_arm_menu_postcondition(long menu, long item);
void now_act_clear_menu_postcondition(void);

/* One cooperative yield of the act plane's own shape: pump the wire,
   renew the writer lease, give the processor up without dequeuing an
   event. Exposed so a verb can wait for ITS OWN evidence rather than for
   a trap patch - `ctlact part 0` asks for no patch and must watch the
   control instead (act_cmds.c). Never spin in its place; act_yield's
   comment says why, and the spin guarantees the timeout it waits out. */
void now_act_yield_once(void);

/* Record what the APPLICATION itself observed about the act it just
   sent: 1 when it proved the effect, 0 when it looked and could not.
   Does nothing unless this command registered a correlation. */
void now_act_note_observed(int confirmed);

void now_act_begin_command(void);
long now_act_encode_settlements(char *out, long cap);

/* NOTE: there is deliberately NO post-a-click entry point here.
   The RESIDENT plane queues its own press, inside the target process, at
   the moment it arms - see act_post_click() in ext/src/now_ext_act.c.
   Two reasons, and the second is the one that would have bitten:

     - PPostEvent and the low-memory mouse globals are CALL_NOT_IN_CARBON,
       and this application is Carbon. It cannot queue an event whose
       `where` it controls, and `where` is this plane's identity check.
     - Posting from the target's own context closes the gap between
       "armed" and "pressed" during which a user's click could arrive
       first - which is precisely the hijack the guard exists for.

   Upstream posts from its application because upstream's application is
   a classic PPC binary. This is the one place the port diverges in
   design rather than in spelling. */

/* Wait for the armed patch to answer, then snapshot. */
NowActStatus now_act_await_fired(NowPeekActCell *snapshot);

/* Put the cell back to idle and disarm, ALWAYS, on every path out. A
   request left armed is a patch waiting to fire on somebody else's
   click, which is the one failure mode a trap patch must not have. */
void now_act_withdraw(void);

/* The plane's own error code as a short kebab word for the wire, and a
   sentence for a person. Both name the failure rather than collapsing
   it; `unknown` is never returned for a code this build declares. */
const char *now_act_error_code(unsigned long plane_error);
const char *now_act_error_message(unsigned long plane_error);
const char *now_act_status_code(NowActStatus status);
const char *now_act_status_message(NowActStatus status);

#endif /* NOW_ACT_CLIENT_H */
