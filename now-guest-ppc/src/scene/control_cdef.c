/* The documented CDEF table. See control_cdef.h for why this is a
   weaker claim than a kind and what it is allowed to say.

   PROVENANCE OF EVERY ROW: Universal Interfaces 3.4 as shipped with this
   toolchain, `ControlDefinitions.h`, cited by line number beside each
   family. `procID = 16 * CDEF_id + variant` is the Control Manager's
   arithmetic (Inside Macintosh: Macintosh Toolbox Essentials, "Creating
   a Control"), so a `*Proc` constant of 384 is CDEF 24 variant 0.

   Nothing here is inferred from a name, a size, or a neighbour. */

#include "control_cdef.h"

const char *now_cdef_role(short cdef_id, short variant)
{
    if (variant < 0) {
        return 0;
    }
    switch (cdef_id) {
    case 0:
        /* ControlDefinitions.h:147-149 - pushButProc 0, checkBoxProc 1,
           radioButProc 2. The classic family, and the reason a family id
           alone is not an answer. */
        if (variant == 0) return "button";
        if (variant == 1) return "checkbox";
        if (variant == 2) return "radio";
        return 0;
    case 1:
        /* :150 scrollBarProc = 16. Only variant 0 is declared. */
        return variant == 0 ? "scrollbar" : 0;
    case 2:
        /* :248-250 bevel button, three bevel depths. A bevel button is a
           button in every way this product acts on one. */
        return (variant >= 0 && variant <= 2) ? "button" : 0;
    case 4:
        /* :607-610 disclosure triangle, four facing/toggle variants. */
        return (variant >= 0 && variant <= 3) ? "triangle" : 0;
    case 5:
        /* :678 progress bar. :679 is the relevance bar, which is an
           indicator of a different thing and gets no role rather than a
           near-enough one. */
        return variant == 0 ? "progress" : 0;
    case 8:
        /* :821-830 tabs - large/small, north/south/east/west. Every one
           of the eight is declared, so every one is attributable. */
        return (variant >= 0 && variant <= 7) ? "tab" : 0;
    case 10:
        /* :988-993 group box: text title, check box title, popup title,
           and the three secondary variants. All six are group boxes; the
           title flavour changes the drawing, not the kind. */
        return (variant >= 0 && variant <= 6 && variant != 3)
               ? "group" : 0;
    case 11:
        /* :1100 image well. */
        return variant == 0 ? "imageWell" : 0;
    case 16:
        /* :1366 user pane. */
        return variant == 0 ? "userPane" : 0;
    case 17:
        /* :1914-1920 edit text, password, inline input. */
        return (variant == 0 || variant == 2 || variant == 4) ? "edit" : 0;
    case 18:
        /* :2054 static text. */
        return variant == 0 ? "static" : 0;
    case 21:
        /* :2200-2201 window header, and the list-view variant. */
        return (variant == 0 || variant == 1) ? "header" : 0;
    case 22:
        /* :2238-2239 list box, and its auto-size variant. */
        return (variant == 0 || variant == 1) ? "listBox" : 0;
    case 23:
        /* :2311-2321 the Appearance button family. 0 push, 1 check,
           2 radio, 3 check auto-toggle, 4 radio auto-toggle, 6 and 7 the
           icon-bearing push buttons. 5 is declared by nobody and gets
           nothing. */
        if (variant == 0 || variant == 6 || variant == 7) return "button";
        if (variant == 1 || variant == 3) return "checkbox";
        if (variant == 2 || variant == 4) return "radio";
        return 0;
    case 24:
        /* :2424-2425 scroll bar, and the live-scrolling variant. */
        return (variant == 0 || variant == 2) ? "scrollbar" : 0;
    case 25:
        /* :2476 popup button. */
        return variant == 0 ? "popup" : 0;
    case 57:
        /* :5686-5687 Unicode edit text, and its password variant. */
        return (variant == 0 || variant == 2) ? "edit" : 0;
    case 63:
        /* :151 popupMenuProc = 1008, the classic popup. */
        return variant == 0 ? "popup" : 0;
    default:
        /* Every other id - including the documented ones this product has
           no honest role for - says nothing. */
        return 0;
    }
}
