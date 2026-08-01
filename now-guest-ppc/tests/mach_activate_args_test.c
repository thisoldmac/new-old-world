/* Native test for `activate`'s parse and verdict. Runs on the host:

       cc -Wall -Wextra -Werror -I ../src/machine -I ../src/core \
          mach_activate_args_test.c ../src/machine/mach_activate_args.c \
          ../src/core/json.c -o t && ./t

   TWO THINGS ARE BEING WATCHED HERE, and both are silent on a Macintosh.

   The PARSE addresses a process by identity, so half a PSN, an overflowed
   one, or a zero must be REFUSED rather than defaulted - a defaulted half
   names a different, real process and fronts it.

   The VERDICT must never call an accepted switch a completed one. On a
   cooperative system SetFrontProcess returning noErr means scheduled;
   only the re-read can say frontmost. Upstream's measurement discipline
   has four retracted findings from exactly this collapse. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mach_activate_args.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

static NowMachActivateFacts ok_facts(void)
{
    NowMachActivateFacts f;

    f.found = 1;
    f.background_only = 0;
    f.was_front = 0;
    f.set_called = 1;
    f.set_err = 0;
    f.confirmed_front = 1;
    return f;
}

int main(void)
{
    NowMachPsnArg        psn;
    NowMachActivateFacts f;
    int                  i;

    /* --- the typed caller: the host's own two fields ------------------ */
    check(now_mach_psn_parse("{\"serialHi\":0,\"serialLo\":8781}", "",
                             &psn)
              && psn.hi == 0UL && psn.lo == 8781UL && psn.present,
          "serialHi/serialLo, as MirrorKit sends them");
    check(now_mach_psn_parse("{\"serialHi\":\"0\",\"serialLo\":\"8781\"}",
                             "", &psn)
              && psn.lo == 8781UL,
          "quoted halves parse too");
    check(now_mach_psn_parse("{\"serialHi\":1,\"serialLo\":0}", "", &psn)
              && psn.hi == 1UL && psn.lo == 0UL,
          "a zero LOW half is legal when the high half is set");

    /* --- half a PSN is not a PSN ------------------------------------- */
    check(!now_mach_psn_parse("{\"serialHi\":0}", "", &psn),
          "serialHi alone is refused");
    check(!now_mach_psn_parse("{\"serialLo\":8781}", "", &psn),
          "serialLo alone is refused");
    check(!now_mach_psn_parse("{\"serialLo\":8781}", "", &psn)
              && psn.present == 0 && psn.hi == 0 && psn.lo == 0,
          "and a refused parse leaves nothing usable behind");
    /* The typed fields do NOT fall back to the line: a caller that sent
       one half sent a broken request, and quietly reading the line
       instead would front whatever the line named. */
    check(!now_mach_psn_parse("{\"serialHi\":0}", "1 2", &psn),
          "a broken typed request never falls through to the line");

    /* --- 0.0 is kNoProcess, not a target ----------------------------- */
    check(!now_mach_psn_parse("{\"serialHi\":0,\"serialLo\":0}", "", &psn),
          "0.0 is kNoProcess and is refused");
    check(!now_mach_psn_parse("{}", "0 0", &psn),
          "0 0 on the line is refused for the same reason");

    /* --- wider than a PSN half --------------------------------------- *
     * Saturating would name a real, different process. */
    check(!now_mach_psn_parse("{\"serialHi\":0,"
                              "\"serialLo\":99999999999}", "", &psn),
          "a number wider than 32 bits is refused, not clamped");
    check(now_mach_psn_parse("{\"serialHi\":0,\"serialLo\":4294967295}",
                             "", &psn)
              && psn.lo == 4294967295UL,
          "the widest legal half still parses");

    /* --- the human spelling ------------------------------------------ */
    check(now_mach_psn_parse("{}", "0 8781", &psn)
              && psn.hi == 0UL && psn.lo == 8781UL,
          "two numbers on the line, high first");
    check(now_mach_psn_parse("{}", "   0   8781  ", &psn)
              && psn.lo == 8781UL,
          "leading and inner spaces do not matter");
    check(!now_mach_psn_parse("{}", "8781", &psn),
          "one number on the line is half a PSN and is refused");
    check(!now_mach_psn_parse("{}", "", &psn), "a bare line is refused");
    check(!now_mach_psn_parse("{}", "Finder", &psn),
          "a NAME is not this verb's argument - `front` takes those");
    check(!now_mach_psn_parse(NULL, NULL, &psn), "NULLs fail closed");
    check(!now_mach_psn_parse("{}", NULL, &psn), "a NULL line fails closed");

    /* --- the verdict -------------------------------------------------- */
    f = ok_facts();
    check(now_mach_activate_verdict(&f) == kNowMachActivateDone,
          "asked, and the re-read names it: done");
    f = ok_facts();
    f.confirmed_front = 0;
    check(now_mach_activate_verdict(&f) == kNowMachActivateUnconfirmed,
          "accepted and not yet observable is NOT done");
    check(!now_mach_activate_is_front(kNowMachActivateUnconfirmed),
          "and unconfirmed is not the asked-for state");
    check(now_mach_activate_is_front(kNowMachActivateDone)
              && now_mach_activate_is_front(kNowMachActivateAlreadyFront),
          "done and already-front are the asked-for state");

    f = ok_facts();
    f.was_front = 1;
    f.set_called = 0;
    check(now_mach_activate_verdict(&f) == kNowMachActivateAlreadyFront,
          "already frontmost: nothing is asked of the machine");
    /* A process that IS frontmost demonstrably can be, whatever its
       mode flag says. The machine wins. */
    f = ok_facts();
    f.was_front = 1;
    f.background_only = 1;
    f.set_called = 0;
    check(now_mach_activate_verdict(&f) == kNowMachActivateAlreadyFront,
          "a background-only flag loses to an observed frontmost process");

    f = ok_facts();
    f.background_only = 1;
    check(now_mach_activate_verdict(&f) == kNowMachActivateBackgroundOnly,
          "background-only is refused before anything is asked");
    f = ok_facts();
    f.found = 0;
    check(now_mach_activate_verdict(&f) == kNowMachActivateNoSuchProcess,
          "a stale PSN names nothing alive");
    /* Staleness outranks everything: the other fields describe a process
       that is not there. */
    f = ok_facts();
    f.found = 0;
    f.was_front = 1;
    check(now_mach_activate_verdict(&f) == kNowMachActivateNoSuchProcess,
          "and it outranks a stale was_front reading");

    f = ok_facts();
    f.set_err = -600;
    check(now_mach_activate_verdict(&f) == kNowMachActivateRefused,
          "SetFrontProcess failing is a refusal");
    f = ok_facts();
    f.set_called = 0;
    check(now_mach_activate_verdict(&f) == kNowMachActivateRefused,
          "and never calling it is not a success either");
    /* A confirmed re-read must not paper over a failed call: the front
       process may be the one we wanted for an unrelated reason. */
    f = ok_facts();
    f.set_err = -600;
    f.confirmed_front = 1;
    check(now_mach_activate_verdict(&f) == kNowMachActivateRefused,
          "a lucky re-read does not turn a failed call into a success");
    check(now_mach_activate_verdict(NULL) == kNowMachActivateBadArgs,
          "NULL facts fail closed");

    /* --- the words ---------------------------------------------------- */
    for (i = 0; i <= (int)kNowMachActivateBadArgs; i++) {
        NowMachActivateOutcome o = (NowMachActivateOutcome)i;

        check(now_mach_activate_code(o)[0] != '\0',
              "every declared outcome has a wire code");
        check(strlen(now_mach_activate_message(o)) > 20,
              "every declared outcome has a sentence");
    }
    check(strcmp(now_mach_activate_code(kNowMachActivateDone),
                 now_mach_activate_code(kNowMachActivateUnconfirmed)) != 0,
          "done and unconfirmed do not share a code");

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("mach_activate_args: all checks passed\n");
    return EXIT_SUCCESS;
}
