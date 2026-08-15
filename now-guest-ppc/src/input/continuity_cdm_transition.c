/* PowerPC Cursor Device Manager transition for the Carbon guest.

   CursorDevices.h says PowerPC callers need CursorDevicesGlue.o because the
   original ROM/InterfaceLib Mixed Mode transition is wrong. Apple's supplied
   object has two routes: fixed InterfaceLib exports when Gestalt says they are
   safe, or NGetTrapAddress(_CursorDeviceDispatch, ToolTrap) followed by
   CallUniversalProc with a selector-specific ProcInfoType.

   A Carbon CFM application cannot strongly import the former routines: they
   are CALL_NOT_IN_CARBON, and pulling Retro68's monolithic InterfaceLib import
   member makes NOW unload before main on Mac OS 9.1. This file reproduces the
   latter, corrected route exactly for the seven calls Continuity owns. Both
   transition functions are resolved at runtime, following the metal-proven
   census trap seam, so the PEF remains a Carbon application. */
#include "continuity_cdm_transition.h"

#include <Carbon.h>
#include <MixedMode.h>

enum {
    kNowCursorDeviceDispatch = 0xAADB,
    kNowToolboxTrapType = 1,

    /* Values disassembled from Apple's CursorDevicesGlue.o. They encode the
       result plus selector and argument widths for CallUniversalProc. */
    kNowCDMProcInfoOnePointer = 0x03E8,
    kNowCDMProcInfoPointerShort = 0x0BE8,
    kNowCDMProcInfoPointerLong = 0x0FE8,
    kNowCDMProcInfoPointerLongLong = 0x3FE8,

    kNowCDMMoveTo = 1,
    kNowCDMButtonDown = 4,
    kNowCDMButtonUp = 5,
    kNowCDMSetButtons = 7,
    kNowCDMUnitsPerInch = 10,
    kNowCDMNewDevice = 12,
    kNowCDMDisposeDevice = 13
};

typedef long (*CallUPPProc)(UniversalProcPtr, ProcInfoType, ...);
typedef UniversalProcPtr (*NGetTrapAddressProc)(UInt16, signed char);

static CallUPPProc gCallUPP;
static NGetTrapAddressProc gGetTrap;
static UniversalProcPtr gDispatch;
static int gResolverState;             /* 0 unknown, 1 ready, -1 unavailable */

static int find_interface_symbol(CFragConnectionID conn, const char *name,
                                 Ptr *address)
{
    Str255 proc_name;
    CFragSymbolClass symbol_class;

    CopyCStringToPascal(name, proc_name);
    return FindSymbol(conn, proc_name, address, &symbol_class) == noErr;
}

int now_cdm_transition_ready(void)
{
    CFragConnectionID conn = 0;
    Ptr main_address = NULL;
    Ptr address = NULL;
    Str255 error_name;
    Str255 library_name;

    if (gResolverState != 0)
        return gResolverState == 1;
    gResolverState = -1;
    CopyCStringToPascal("InterfaceLib", library_name);
    if (GetSharedLibrary(library_name, kPowerPCCFragArch, kReferenceCFrag,
                         &conn, &main_address, error_name) != noErr)
        return 0;
    if (!find_interface_symbol(conn, "CallUniversalProc", &address))
        return 0;
    gCallUPP = (CallUPPProc)address;
    if (!find_interface_symbol(conn, "NGetTrapAddress", &address))
        return 0;
    gGetTrap = (NGetTrapAddressProc)address;
    gDispatch = gGetTrap((UInt16)kNowCursorDeviceDispatch,
                         (signed char)kNowToolboxTrapType);
    if (gDispatch == NULL)
        return 0;
    gResolverState = 1;
    return 1;
}

OSErr now_cdm_new_device(CursorDevicePtr *device)
{
    if (!now_cdm_transition_ready())
        return unimpErr;
    return (OSErr)gCallUPP(gDispatch, kNowCDMProcInfoOnePointer,
                           kNowCDMNewDevice, device);
}

OSErr now_cdm_dispose_device(CursorDevicePtr device)
{
    if (!now_cdm_transition_ready())
        return unimpErr;
    return (OSErr)gCallUPP(gDispatch, kNowCDMProcInfoOnePointer,
                           kNowCDMDisposeDevice, device);
}

OSErr now_cdm_set_buttons(CursorDevicePtr device, short count)
{
    if (!now_cdm_transition_ready())
        return unimpErr;
    return (OSErr)gCallUPP(gDispatch, kNowCDMProcInfoPointerShort,
                           kNowCDMSetButtons, device, count);
}

OSErr now_cdm_units_per_inch(CursorDevicePtr device, Fixed resolution)
{
    if (!now_cdm_transition_ready())
        return unimpErr;
    return (OSErr)gCallUPP(gDispatch, kNowCDMProcInfoPointerLong,
                           kNowCDMUnitsPerInch, device, resolution);
}

OSErr now_cdm_move_to(CursorDevicePtr device, long abs_x, long abs_y)
{
    if (!now_cdm_transition_ready())
        return unimpErr;
    return (OSErr)gCallUPP(gDispatch, kNowCDMProcInfoPointerLongLong,
                           kNowCDMMoveTo, device, abs_x, abs_y);
}

OSErr now_cdm_button_down(CursorDevicePtr device)
{
    if (!now_cdm_transition_ready())
        return unimpErr;
    return (OSErr)gCallUPP(gDispatch, kNowCDMProcInfoOnePointer,
                           kNowCDMButtonDown, device);
}

OSErr now_cdm_button_up(CursorDevicePtr device)
{
    if (!now_cdm_transition_ready())
        return unimpErr;
    return (OSErr)gCallUPP(gDispatch, kNowCDMProcInfoOnePointer,
                           kNowCDMButtonUp, device);
}
