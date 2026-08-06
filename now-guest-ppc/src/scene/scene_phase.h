#ifndef NOW_SCENE_PHASE_H
#define NOW_SCENE_PHASE_H

/* WHERE A SCENE'S TIME WENT, carried by the scene itself.
 *
 * A scene used to report one number - `latencyMs`, the whole collect -
 * and every question about guest cost was answered by differencing two
 * runs. On 2026-08-06 that produced a confident WRONG answer: the cost
 * of a ~1 s self-front scene was attributed to the menu bar, and a
 * microsecond breakdown then showed the menu bar to be 0.1% of it while
 * a FindControl grid sweep was ~95%. The differential lied because the
 * two conditions differed by two variables, not one, and nothing in the
 * scene could say so. This module is that breakdown made permanent, so
 * the next such question is a lookup rather than an argument.
 *
 * PHASES ARE NAMED FOR WHAT THE GUEST DOES, not for the function that
 * happens to implement it today. `controls` is "finding out which
 * controls a window has", whether that is a memory walk in a foreign
 * process or a FindControl sweep in our own; renaming the function must
 * not rename the number, or a year of measurements stops comparing.
 *
 * THE PHASES DO NOT OVERLAP. Entering a phase suspends its parent and
 * leaving resumes it, so every microsecond is charged to exactly one
 * phase and the sum is never more than the walk. What the sum is LESS
 * than the walk by is real and unattributed - it is the collector's own
 * bookkeeping - and a consumer that wants it subtracts rather than being
 * handed a fabricated "other".
 *
 * IT IS CHEAP ENOUGH TO LEAVE ON, and it says so rather than asking to
 * be believed: every clock read is counted, the clock's own cost is
 * calibrated once at startup, and `clockUs` publishes the product. A
 * breakdown that cost 8% of the thing it measures is not a breakdown,
 * and on a machine this slow that is a real risk rather than a
 * theoretical one - so the seams are placed where their COUNT is bounded
 * by processes and windows, never by controls or menu items.
 *
 * NO TOOLBOX HERE, deliberately. The clock is injected, which is what
 * lets scene_phase_test.c drive the arithmetic - overlap, nesting,
 * counter wrap - on a host compiler with a clock that does what the test
 * says. See now-guest-ppc/tests/scene_phase_test.c. */

enum {
    /* Asking the Process Manager who is running, and reading each
       process's name, signature and incarnation. */
    kNowScenePhaseEnumerate = 0,
    /* Attaching to one process's context so its own chains can be read. */
    kNowScenePhaseBind,
    /* Walking a process's window chain and admitting its windows. */
    kNowScenePhaseWindows,
    /* Finding out which controls a window has, and reading each. */
    kNowScenePhaseControls,
    /* Reading the front application's menu bar, titles and items. */
    kNowScenePhaseMenubar,
    /* Joining a resident's semantic facts onto what the walk found. */
    kNowScenePhaseSemantics,
    /* Minting the act plane's references for windows and controls. */
    kNowScenePhaseRefs,
    /* Turning the collected scene into the IR document. */
    kNowScenePhaseEncode,
    kNowScenePhaseCount
};

/* Deep enough for enumerate > bind > windows > controls > refs and the
   two the menu bar nests. A push past it is dropped, counted, and popped
   symmetrically, so an unbalanced depth can never corrupt the numbers -
   it can only make one of them low, and `dropped` says it happened. */
enum { kNowScenePhaseDepthMax = 8 };

/* Installs the clock. Microseconds, on the guest; whatever a test wants,
   in a test. UNTIL THIS IS CALLED NOTHING IS REPORTED, which is the
   honest default: a producer that cannot read a clock says nothing about
   phases rather than reporting eight zeroes, and zero is a measurement. */
void now_scene_phase_set_clock(unsigned long (*clock_us)(void));

/* Times the clock against itself, once, so the breakdown can publish its
   own cost. Safe to call repeatedly; only the first call measures. */
void now_scene_phase_calibrate(void);

/* Start of one scene. Clears every accumulator and the stack. */
void now_scene_phase_reset(void);

void now_scene_phase_enter(int phase);
void now_scene_phase_leave(int phase);

/* True when a clock is installed and this scene actually measured. When
   false the encoder emits NOTHING - see the absence rule in
   contract/asyncapi.yaml. */
int now_scene_phase_reporting(void);

const char *now_scene_phase_name(int phase);
unsigned long now_scene_phase_us(int phase);

/* How many times the clock was read this scene, and what that cost at
   the calibrated per-read price. `clockUs` is an estimate and is named
   as one on the wire; it exists so a reader can see the measurement's
   own weight beside the numbers it produced. */
unsigned long now_scene_phase_clock_reads(void);
unsigned long now_scene_phase_clock_us(void);

/* Enters that found no room on the stack, and leaves that did not match
   the phase on top of it. Both are programming errors in the seams, not
   conditions a machine can produce; they are counted rather than
   asserted because a scene must still be served. Non-zero means one of
   the numbers below is wrong, and the wire says so. */
unsigned long now_scene_phase_faults(void);

#endif /* NOW_SCENE_PHASE_H */
