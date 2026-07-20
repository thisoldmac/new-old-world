#include "Types.r"
#include "Processes.r"
#include "Dialogs.r"
#include "Finder.r"

type 'NOWo' as 'STR ';
resource 'NOWo' (0, purgeable) {
    "New Old World"
};

resource 'BNDL' (128) {
    'NOWo', 0,
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
    /* Must be doesActivateOnFGSwitch: with needsActivateOnFGSwitch set,
       CarbonLib refuses to start the process on OS 9 ("could not start
       up"). Carbon apps handle their own activation. */
    doesActivateOnFGSwitch,
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
    6 * 1024 * 1024,
    3 * 1024 * 1024
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

resource 'DLOG' (300) {
    {120, 140, 302, 560},
    movableDBoxProc,
    invisible,
    noGoAway,
    0,
    300,
    "Connection",
    centerMainScreen
};

resource 'DITL' (300) {
    {
        /* 1 Save   */ {146, 330, 166, 400}, Button { enabled, "Save" };
        /* 2 Cancel */ {146, 244, 166, 314}, Button { enabled, "Cancel" };
        /* 3 Connect */ {146, 20, 166, 130},
            Button { enabled, "Connect" };
        /* 4 host   */ {24, 110, 40, 300}, EditText { enabled, "" };
        /* 5 port   */ {54, 110, 70, 180}, EditText { enabled, "" };
        /* 6 status */ {88, 20, 132, 400}, StaticText { disabled, "" };
        /* 7 */ {24, 20, 40, 100}, StaticText { disabled, "Host:" };
        /* 8 */ {54, 20, 70, 100}, StaticText { disabled, "Port:" };
    }
};


resource 'MENU' (130) {
    130, textMenuProc, allEnabled, enabled, "Depth",
    {
        "1-bit", noIcon, noKey, noMark, plain;
        "2-bit", noIcon, noKey, noMark, plain;
        "4-bit", noIcon, noKey, noMark, plain;
        "8-bit", noIcon, noKey, noMark, plain;
        "16-bit", noIcon, noKey, noMark, plain;
        "32-bit", noIcon, noKey, noMark, plain
    }
};

resource 'MENU' (131) {
    131, textMenuProc, allEnabled, enabled, "Chunk",
    {
        "1 K", noIcon, noKey, noMark, plain;
        "2 K", noIcon, noKey, noMark, plain;
        "4 K", noIcon, noKey, noMark, plain;
        "8 K", noIcon, noKey, noMark, plain;
        "16 K", noIcon, noKey, noMark, plain;
        "32 K", noIcon, noKey, noMark, plain
    }
};

resource 'MENU' (132) {
    132, textMenuProc, allEnabled, enabled, "Pacing",
    {
        "None", noIcon, noKey, noMark, plain;
        "2 ms", noIcon, noKey, noMark, plain;
        "5 ms", noIcon, noKey, noMark, plain;
        "10 ms", noIcon, noKey, noMark, plain;
        "20 ms", noIcon, noKey, noMark, plain
    }
};
