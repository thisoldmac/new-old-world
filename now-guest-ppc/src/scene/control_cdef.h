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
 *   whose state a caller would then read wrong.
 *
 * THE VARIATION CODE IS NOT READABLE FOR A FOREIGN CONTROL, and that is
 * a measurement rather than a caution. On the emulator, 2026-08-07, over
 * Memory's 44 controls and Date & Time's 21:
 *
 * - Every button-family control - push buttons, check boxes and radio
 *   buttons alike - reported `contrlDefProc` = 0x00002EC8, high byte
 *   ZERO. Memory's "Save contents to" (a check box) and its three On/Off
 *   pairs (radio buttons) are byte-identical in that field to "Use
 *   Defaults" (a push button). The classic packing of the variation code
 *   into that byte, which the resolver's mask path exists to undo, is
 *   simply not what Mac OS 9 does with these.
 * - `GetControlVariant` - the Control Manager's own accessor, CarbonLib
 *   1.0 and later - answered 0 for all 65 of them.
 *
 * That second line would say nothing on its own, because 0 is also what
 * a declined call returns. So it was asked of controls THIS APPLICATION
 * CREATED, whose variants are in this repository's own source: NOW's two
 * `checkBoxProc` boxes answered 1, its `kControlScrollBarLiveProc` bar
 * and its auto-toggle triangle answered 2, its push buttons and popup 0.
 * The accessor works on this runtime and is right every time about a
 * control we own. It is foreign controls it cannot answer for.
 *
 * SO CDEF 0 AND CDEF 23 ATTRIBUTE NOTHING AT ALL, not even variant 0.
 * Reading zero from a field that is zero for all three kinds is not
 * evidence of a push button; it is the absence of evidence, wearing the
 * push button's number. The rule this file already states - an
 * approximate role would authorise an approximate act - does not have an
 * exception for the most common control on the screen.
 *
 * THE COST IS REAL AND IS STATED HERE RATHER THAN DISCOVERED LATER. Those
 * controls fall back to `unknown`, and `Semantics.authorizesAction`
 * requires `known` or `derived`, so a driver that honours it will now
 * DECLINE them where it used to press them. `ctlact` with an explicit
 * point still reaches them - the guest checks the point against the rect
 * the resolver proved and never consults the kind - so what is lost is
 * the semantic authority, not the mechanism.
 *
 * That is the trade this project has already decided twice, and it is
 * worth naming which way: a check box pressed as a push button is not a
 * near miss. Its `state` is never reported, so a caller cannot read what
 * it did, and a radio button in a group of three is reported as three
 * independent buttons with no exclusivity between them. An `unknown` a
 * driver declines is a gap someone can close. A `pushButton` that is
 * really a check box is a gap nobody will ever look for. */

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
