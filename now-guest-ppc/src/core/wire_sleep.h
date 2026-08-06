#ifndef NOW_WIRE_SLEEP_H
#define NOW_WIRE_SLEEP_H

/* How long the main loop may sleep, as a rule rather than an expression.

   It lives in its own Toolbox-free file because it is the most expensive
   arithmetic in this application: on 2026-08-06 the whole of a scene
   round trip's unexplained 115 ms turned out to be this number, and
   every alternative to it is a judgement about what the Macintosh owes
   other processes. A rule that costs a tenth of a second per request
   should be executable by a test, not inferred from a ternary in an
   event loop.

   THREE FACTS DECIDE IT, and the order matters:

   1. NEVER ZERO. A zero sleep tells WaitNextEvent to return at once, so
      this application spins and, on a cooperatively scheduled Macintosh,
      nothing else runs. That is fatal for a MIRROR specifically: the
      anchor plane captures a process's A5 when that process pumps, so
      starving the machine starves the mirror of everything except its
      own window. Watched 2026-08-03.
   2. WORK IN FLIGHT sleeps one tick. A transfer, stream, offer, put or
      queued control frame needs the loop spinning; one tick still
      yields.
   3. BYTES ALREADY ANNOUNCED sleep one tick. Open Transport has said
      data is here and this loop has not taken it yet, so there is
      nothing to wait for. This is what closes the wake's one race - a
      notification that lands while the process is already awake finds
      WakeUpProcess with nothing to wake, and without this the request
      waits out the next full sleep.

   Otherwise the idle sleep, which is a policy about the rest of the Mac
   and not about the wire. */

/* All arguments are 0/1; `idle_ticks` is the configured idle sleep.
   Returns at least 1, always. */
long now_wire_sleep_ticks(int work_in_flight, int bytes_announced,
                          long idle_ticks);

/* The idle sleep, clamped to the range this application will honour.
   One tick is the floor for rule 1; sixty (one second) is the ceiling
   because a wire whose heartbeat is measured in seconds cannot report a
   dead link inside its own timeouts. */
long now_wire_clamp_idle(long ticks);

#endif
