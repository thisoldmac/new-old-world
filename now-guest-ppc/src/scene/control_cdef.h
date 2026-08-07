#ifndef NOW_CONTROL_CDEF_H
#define NOW_CONTROL_CDEF_H

/* **What draws this control, when the Control Manager will not say what
 * it IS.**
 *
 * The authoritative question - `GetControlData(kControlKindTag)` - is
 * answered only for controls built through the Appearance-era
 * `Create*Control` calls. Mac OS 9's own control panels are `CNTL`
 * -resource controls from `GetNewControl`, and the Control Manager
 * declines them: measured on the emulator 2026-08-07, Appearance
 * answered 2 of 73 and Date & Time 0 of 21. (`GetControlKind` itself is
 * Mac OS X only - Universal Interfaces `Controls.h:2310` - so there is
 * no stronger call to reach for.)
 *
 * What is still available is the control's DEFINITION FUNCTION.
 * `contrlDefProc` holds a Handle to the loaded CDEF, and a CDEF supplied
 * by the System file is a resource in every process's resource chain, so
 * the Resource Manager can name it: type `CDEF`, and an ID. That ID is
 * not a guess - `procID = 16 * CDEF_id + variant` is the Control
 * Manager's own arithmetic, and every ID below is a `*Proc` constant
 * this toolchain's `ControlDefinitions.h` declares, cited by line.
 *
 * IT IS STILL A WEAKER CLAIM THAN A KIND, and it must stay visibly
 * weaker. `kControlKindTag` is the control answering about itself; this
 * is us reading the identity of the code that draws it and looking the
 * meaning up in a header. Those differ exactly where a CDEF is
 * overloaded, so the answer travels as its own knowledge level
 * (`derived`) with its own provenance (`guest-cdef-resource`), never
 * merged into `known`.
 *
 * TWO RULES, both of which cost something to keep:
 *
 * - **An ID this file cannot attribute stays unmapped.** There is no
 *   "probably the scroll bar one". Only IDs with a documented constant
 *   are here, and several documented ones are deliberately absent
 *   (slider, clock, placard, icon, picture, separator, little/chasing
 *   arrows, popup arrow, radio group, scroll text box) because this
 *   product's role vocabulary has no honest word for them - an
 *   approximate role would authorise an approximate act.
 * - **A variant this file cannot attribute stays unmapped**, even where
 *   the family is known. CDEF 0 and CDEF 23 are the button FAMILY:
 *   variant 0 is a push button, 1 a check box, 2 a radio button, and
 *   returning "button" for all three would put a press on a control
 *   whose state a caller would then read wrong. */

/* Whether the Resource Manager could name a control's definition
   function - a fact about the LOOKUP, kept separate from what the answer
   meant, so "we never asked" can never read as "there is nothing there".
   Zero is the nothing-happened value so a zeroed scene carries it. */
typedef enum {
    kNowCdefUnattempted = 0,  /* not a system-heap handle, so not asked */
    kNowCdefNamed = 1,        /* the Resource Manager named a `CDEF` */
    kNowCdefUnnamed = 2,      /* asked; this handle is in no resource map */
    kNowCdefNotCdef = 3       /* named, and it is not a `CDEF` */
} NowCdefState;

/* The IR role for a documented CDEF id and variation code, or NULL when
   this file will not attribute one. NULL is the common answer and the
   safe one. */
const char *now_cdef_role(short cdef_id, short variant);

#endif
