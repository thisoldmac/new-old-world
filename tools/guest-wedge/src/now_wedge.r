/*
 * The dialog the `modal` mode puts up.
 *
 * Decoration, not the experiment: the GetNextEvent loop in ModalUntil is
 * what answers whether a pumping nested loop starves background
 * applications, and it runs whether or not this resource is found. This
 * exists so the run LOOKS like the case it stands in for, and so a person
 * watching the screen can see which mode is running.
 */

#include "Dialogs.r"

resource 'DLOG' (128) {
    {100, 100, 190, 420},
    dBoxProc,
    visible,
    noGoAway,
    0x0,
    128,
    "",
    noAutoCenter
};

resource 'DITL' (128) {
    {
        /* Not a button. A dismissable control would let a stray click end
           an experiment early, and the run's duration would stop being
           the thing its name asked for. */
        {20, 20, 40, 300}, StaticText { disabled, "NOW Wedge - starving this Macintosh" },
        {50, 20, 70, 300}, StaticText { disabled, "It releases itself. Nothing to do." }
    }
};
