#ifndef NOW_CONTINUITY_CDM_TRANSITION_H
#define NOW_CONTINUITY_CDM_TRANSITION_H

#include <CursorDevices.h>

/* The bounded PowerPC transition Apple ships in CursorDevicesGlue.o, exposed
   separately so a Carbon CFM application does not acquire strong InterfaceLib
   imports and die before main. */
int now_cdm_transition_ready(void);
OSErr now_cdm_new_device(CursorDevicePtr *device);
OSErr now_cdm_dispose_device(CursorDevicePtr device);
OSErr now_cdm_set_buttons(CursorDevicePtr device, short count);
OSErr now_cdm_units_per_inch(CursorDevicePtr device, Fixed resolution);
OSErr now_cdm_move_to(CursorDevicePtr device, long abs_x, long abs_y);
OSErr now_cdm_button_down(CursorDevicePtr device);
OSErr now_cdm_button_up(CursorDevicePtr device);

#endif
