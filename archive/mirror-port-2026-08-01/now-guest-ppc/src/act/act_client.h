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
    /* No live process answers to this PSN - GetFrontProcess or
       GetProcessInformation itself failed, before the anchor plane was
       ever asked. The one member of this family that names a process
       rather than an anchor. */
    kNowActNoTarget,
    /* Bound, but no anchor names its A5 world - the resting state for a
       process that has not pumped its event loop since the plane was
       armed. Not an error about the machine. */
    kNowActNoAnchor,
    /* CHANGED 2026-08-01: `now_act_open` used to fold this and the next
       three into `kNowActNoTarget`, so a Finder bind failure and a
       genuinely absent process read identically on the wire - see
       act_client.c:now_act_bind_status, which now gives
       `now_ax_bind_process`'s five NowPeekReadStatus verdicts (axprocess.h)
       one distinct NowActStatus each, the same discipline `refusal_code`
       already applies to the reference layer's five verdicts. Anchors
       are not armed - the plane's own capability flag, not this
       process's. Distinct from `kNowActPlaneDark`, which is the
       resident's OWN table reporting the plane absent; this is the
       narrower race where arming dropped between `now_act_ready` and
       `now_act_open`. */
    kNowActNoPlane,
    /* Two anchor slots claim the same partition, and nothing
       distinguishes them - refused rather than guessed, the same as the
       reference layer's `element-ambiguous`. */
    kNowActAmbiguous,
    /* An anchor claims this partition, but its A5 and its stack base
       describe different address spaces: a recycled slot wearing a
       dead application's anchor. */
    kNowActMismatch,
    /* Bound - the anchor's roots pass the oracle - but its window or
       menu list pointer fails validation against both the partition and
       the system heap. The walk found debris, not an A5 world. */
    kNowActUnreadable,
    /* The target never served the request: not pumping, or suspended. */
    kNowActTimeout,
    /* Served, but the plane did not arm - its patch is missing. */
    kNowActNotArmed,
    /* Armed, the click went, and the application never called the trap.
       The counters in the snapshot say which of the two failures it was. */
    kNowActNotTaken,
    /* Armed, and no pass that MAY queue the press ever ran. Distinct
       from Refused below, and from NotTaken above: three failures, three
       repairs, and collapsing them is how the first two passes at this
       plane each named the wrong one. */
    kNowActClickNoPass,
    /* Armed, a pass ran, and PPostEvent declined the queue element. */
    kNowActClickRefused,
    /* The plane refused it and named why in the snapshot's `error`. */
    kNowActRefused
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

/* The request cell to fill in. NULL when the plane is not usable. */
NowPeekActCell *now_act_cell(void);

/* Post the filled-in cell and wait for the resident plane to serve it,
   then copy a seqlock-coherent snapshot out.

   YIELDS while waiting, and never spins. This is cooperative
   multitasking: a busy-wait holds the processor in THIS process, so the
   target never runs, never pumps, and never serves - the spin
   guarantees the timeout it is waiting through. WaitNextEvent with an
   event mask of ZERO is the documented way to give up the processor
   without dequeuing anything; stealing an event here would break the
   application we are driving.

   It does stall the wire for up to the timeout, and that is stated
   rather than hidden: it belongs with MenuSelect, DragWindow and
   GrowWindow on pump.h's "what cannot be pumped" list, and the bound is
   far inside the host's 75-second idle timeout. */
NowActStatus now_act_submit(unsigned long target_a5, NowPeekActCell *snapshot);

/* Ask for the click, in THIS application's own context, and wait for the
   resident half to say it went. Called between now_act_submit (which
   arms, in the target) and now_act_await_fired (which waits for the
   patch to answer).

   THIS FILE USED TO SAY THERE WAS DELIBERATELY NO SUCH ENTRY POINT, and
   the reasoning read well: the resident half queues the press inside the
   target at the moment it arms, which closes the gap during which a
   user's own click could arrive first. Measured 2026-08-01 on mac99, the
   press queued from there is never delivered - menuact, ctlact and the
   three arming winact ops are 0/10 each, the global FindWindow entry
   counter does not move across a run, and a background window clicked at
   its centre does not even come forward, which needs no patch of ours at
   all. The same context queues a keyDown that IS delivered (`key` with
   modifiers actuates), so it is not that the hook cannot post; it is
   that a mouseDown queued from the receiving process's own pass does not
   arrive. The sibling Mirror project queues its click from its agent's
   process and measures 20/20 on the same four window ops, and that was
   the one structural difference left between the two.

   The Carbon half of the old reasoning still holds and is why this is a
   REQUEST rather than a call: PPostEvent and the low-memory mouse
   globals are CALL_NOT_IN_CARBON, so this application still cannot queue
   the event itself.

   WHAT IT ASKS FOR TODAY, and it is deliberately the weakest of the
   three things it could ask for: the next act pass, whoever it belongs
   to. Not this application's own world (measured 0/6, the ask never
   served) and not "any world but the target's" (measured 0/5, with 293
   to 303 act passes in five seconds and every single one of them in the
   target's own world). A background Carbon application's WaitNextEvent
   does not fall through to the classic Event Manager, so its jGNE filter
   never runs while the wire waits, whatever mask it asks for - mask
   zero, networkMask and everyEvent all measured the same zero passes in
   our world. Upstream's topology, an agent process queueing the press
   for a different target, is therefore not reachable from a Carbon
   binary at all, and saying so is the useful part.

   What the flag still buys, and it is not nothing: the press is queued
   on a pass AFTER the one that armed, which is upstream's ordering and
   is the one part of it this port had never reproduced. That was
   measured too, and it is not the fault either - the press is queued,
   PPostEvent returns a real element, and the application still never
   calls FindWindow. See docs/open-issues.md for what is left.

   The hijack window the old note worried about is real and is NOT what
   guards this plane: upstream measured a self-disarming menu patch
   riding a real user's press 18 times in 20, and the fix was the
   identity check, not the timing. Those checks have not moved. */
NowActStatus now_act_post_click(void);

/* What the last ask saw: how many act passes ran while it stood, and the
   last A5 world that ran one. Zero passes and "no pass" together say the
   hook is not reached from anywhere but the target while the wire waits;
   passes with no post says something declined. */
unsigned long now_act_click_passes(void);
unsigned long now_act_click_last_a5(void);

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
