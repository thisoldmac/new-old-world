#include "Types.r"
#include "Processes.r"
#include "Dialogs.r"
#include "Finder.r"

type 'ScPt' as 'STR ';
resource 'ScPt' (0, purgeable) {
    "Screenshots Prototype"
};

resource 'BNDL' (128) {
    'ScPt', 0,
    {
        'ICN#', { 0, 128 },
        'FREF', { 0, 128 }
    }
};

resource 'FREF' (128) {
    'APPL', 0, ""
};

resource 'ICN#' (128) {
    {
        $"00000000 00000000 0FFFFFF0 10000008"
        $"10000008 13FFFFC8 12000048 12000048"
        $"12000048 12000048 12000048 12000048"
        $"12000048 120FF048 12100848 12200448"
        $"12200448 12200448 12100848 120FF048"
        $"12000048 12000048 12000048 12000048"
        $"12000048 12000048 13FFFFC8 10000008"
        $"10000008 0FFFFFF0 00000000 00000000",
        $"00000000 00000000 0FFFFFF0 1FFFFFF8"
        $"1FFFFFF8 1FFFFFF8 1FFFFFF8 1FFFFFF8"
        $"1FFFFFF8 1FFFFFF8 1FFFFFF8 1FFFFFF8"
        $"1FFFFFF8 1FFFFFF8 1FFFFFF8 1FFFFFF8"
        $"1FFFFFF8 1FFFFFF8 1FFFFFF8 1FFFFFF8"
        $"1FFFFFF8 1FFFFFF8 1FFFFFF8 1FFFFFF8"
        $"1FFFFFF8 1FFFFFF8 1FFFFFF8 1FFFFFF8"
        $"1FFFFFF8 0FFFFFF0 00000000 00000000"
    }
};

resource 'SIZE' (-1) {
    reserved,
    acceptSuspendResumeEvents,
    reserved,
    canBackground,
    needsActivateOnFGSwitch,
    backgroundAndForeground,
    dontGetFrontClicks,
    ignoreChildDiedEvents,
    is32BitCompatible,
    isHighLevelEventAware,
    onlyLocalHLEvents,
    notStationeryAware,
    dontUseTextEditServices,
    reserved,
    reserved,
    reserved,
    4 * 1024 * 1024,
    2 * 1024 * 1024
};

resource 'ALRT' (200) {
    {100, 100, 210, 480},
    200,
    {
        OK, visible, silent;
        OK, visible, silent;
        OK, visible, silent;
        OK, visible, silent
    },
    centerMainScreen
};

resource 'DITL' (200) {
    {
        /* 1 */ {76, 290, 96, 358}, Button { enabled, "OK" };
        /* 2 */ {14, 20, 66, 358}, StaticText { disabled, "^0" };
    }
};

