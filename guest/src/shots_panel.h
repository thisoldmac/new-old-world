#ifndef NOW_SHOTS_PANEL_H
#define NOW_SHOTS_PANEL_H

#include <Carbon.h>

/* The Screenshots control panel: owns the tuning defaults (depth, wire
   compression, chunk size, pacing), a Take Screenshot button, and the
   measurement readout. Settings persist in prefs and are what the
   `screenshot` command and host requests inherit. */

void shots_panel_open(void);
void shots_panel_close(Boolean note_in_prefs);
Boolean shots_panel_is(WindowRef window);
WindowRef shots_panel_ref(void);
void shots_panel_draw(void);
void shots_panel_click(Point local);

#endif
