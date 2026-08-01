#ifndef NOW_MACH_VERBS_H
#define NOW_MACH_VERBS_H

/* Two wire verbs about the MACHINE's own state, folded in from the
   parked upstream project `timbottu/mirror` (docs/mirror-foldin-
   inventory.md, wave 3).
   ------------------------------------------------------------------

   THE EXACT REGISTRATION, because this file cannot perform it - the
   command table is owned elsewhere and one agent is live across it.

   1. now-guest-ppc/src/commands/commands.c, in the same dispatch chain
      as the act plane's six, needs:

          #include "mach_verbs.h"

          if (strcmp(name, "activate") == 0) {
              now_mach_run_activate(request_json, id, out, cap);
              return;
          }
          if (strcmp(name, "actselftest") == 0) {
              now_mach_run_actselftest(request_json, id, out, cap);
              return;
          }

   2. now-guest-ppc/src/commands/cmd_help.c wants a row for each, in the
      table beside `winact`:

          { "activate",    1, "bring one process forward, by serial number",
            "activate <serialHi> <serialLo>", d_activate },
          { "actselftest", 1, "prove the act plane's trap ABI in one process",
            "actselftest [serialHi serialLo]", d_actselftest },

   3. contract/asyncapi.yaml wants a command row for each, both
      x-rowArray outputs like the rest of the act plane's. `activate`'s
      typed arguments are `serialHi` and `serialLo` (integers, both
      required together); `actselftest` takes the same pair, OPTIONAL,
      and means the front process when they are absent.

   4. docs/contract-coverage.md gains a row for each in the same commit
      that registers them - AGENTS.md's rule, and these are exactly the
      case it is for: the guest COMPILES both today and SERVES neither,
      so the inventory would be wrong in either direction if it moved
      before the dispatch chain does.

   The verdicts for the other five verbs this fold-in considered, and the
   evidence behind them, are in docs/mirror-wave3-verdicts.md.

   WHY THE WIRE NAMES ARE THESE. `activate` is the name MirrorKit's
   ActionDispatcher already sends, with those two argument names, so the
   host's Application-menu switch reaches a guest without a host edit.
   `actselftest` is NOT upstream's `portalselftest`: the thing it tests
   here is NOW's act plane, and naming a verb after a component this
   repository does not have would be the only misleading part of the
   port. */

/* Bring one process forward, named by its process serial number.

   This is not a second `front`. `front` takes a NAME and refuses when
   several match; this takes the identity an observation minted, which is
   what a driver has and what the host sends. Underneath, both reach the
   single now_proc_bring_to_front() in src/processes - there is one
   SetFrontProcess in this guest and this verb does not add another.

   The reply reports whether the switch is OBSERVABLE, never merely that
   it was accepted: a cooperative switch lands when this application
   yields, and the two readings keep separate words. */
void now_mach_run_activate(const char *request_json, long id,
                           char *out, long cap);

/* Prove the act plane's trap calling convention, in one process, from
   inside the machine.

   THE PLANE HAS SERVED THIS SINCE IT LANDED AND NOTHING CALLED IT.
   kNowPeekActOpSelfTest is implemented in ext/src/now_ext_act.c and
   routed by now_act_guard.c; there was no path to it from the wire, so
   the one instrument that can catch a wrong trap ABI from inside was
   unreachable.

   It matters more than its size. A patch whose result lands in the wrong
   slot does not crash - it lies: it reports firing, every counter the
   plane owns says success, and the application reads a value that was
   never the one we wrote and takes the other branch. Every other
   instrument reads OUR side of the call. This one reads the caller's:
   the hook makes a real MenuSelect at a point outside the menu bar,
   answers its own call, and compares.

   Side-effect free by construction. Point (0,0) is outside the menu bar,
   so an unanswered call returns 0 immediately without drawing or
   tracking anything, and the arm point is negative - the one op that
   rides no user click at all. */
void now_mach_run_actselftest(const char *request_json, long id,
                              char *out, long cap);

/* Read the act plane's own instruments: the six trap entry counters
   global and target-scoped, the arm state, both click handshakes (the
   cell's V3 ask and the pump's V4 ticket), and the route a click would
   take right now.

   It takes no arguments and reports everything, including "the plane is
   dark" - and it ARMS NOTHING, unlike every other verb here that touches
   the plane. An instrument that installed six trap patches in order to
   answer whether six trap patches are installed would be measuring
   itself.

   The reason it exists is that every number this plane has produced so
   far has been parsed out of a failure SENTENCE, which can only carry
   what its author thought to include. See mach_actstate.c. */
void now_mach_run_actstate(const char *request_json, long id,
                           char *out, long cap);

/* The same report, once, for BOTH faces (docs/command-parity.md). The
   wire face renders these rows into the command.result envelope; the
   Console page renders them as lines. Neither can answer differently
   from the other, because neither of them decides what a row says.

   A callback rather than a returned table because the rows are built by
   walking a shared-memory cell whose fields are read once and in order -
   materialising them twice would be a second reading, and two readings
   of a live table are two different answers. */
typedef void (*NowActStateEmit)(void *ctx, const char *label,
                                const char *value);
void now_mach_actstate_report(NowActStateEmit emit, void *ctx);

#endif /* NOW_MACH_VERBS_H */
