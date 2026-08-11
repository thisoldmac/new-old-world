#ifndef NOW_DB_HILITE_H
#define NOW_DB_HILITE_H

#include <Carbon.h>

/* Asks a Data Browser to hilite the WHOLE selected row rather than
   just its text. SetDataBrowserTableViewHiliteStyle is NOT in the 22
   exports the PB1400c probe proved (spikes/databrowser), and on CFM a
   direct call to an absent export crashes at call time — so it is
   resolved by name at runtime, the ot_carbon.c pattern, and a machine
   that lacks it keeps the minimal hilite it always had. Safe on every
   browser; call once after creation. */
void now_browser_fill_hilite(ControlRef browser);

#endif /* NOW_DB_HILITE_H */
