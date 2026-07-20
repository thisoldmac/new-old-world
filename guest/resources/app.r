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
    {120, 140, 332, 560},
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
        /* 1 Save   */ {176, 330, 196, 400}, Button { enabled, "Save" };
        /* 2 Cancel */ {176, 244, 196, 314}, Button { enabled, "Cancel" };
        /* 3 Connect */ {176, 20, 196, 130},
            Button { enabled, "Connect" };
        /* 4 host   */ {24, 110, 40, 300}, EditText { enabled, "" };
        /* 5 port   */ {54, 110, 70, 180}, EditText { enabled, "" };
        /* 6 status */ {118, 20, 162, 400}, StaticText { disabled, "" };
        /* 7 */ {24, 20, 40, 100}, StaticText { disabled, "Host:" };
        /* 8 */ {54, 20, 70, 100}, StaticText { disabled, "Port:" };
        /* 9 retry */ {84, 110, 100, 160}, EditText { enabled, "" };
        /* 10 */ {84, 20, 100, 100}, StaticText { disabled, "Retry:" };
        /* 11 */ {84, 170, 100, 400},
            StaticText { disabled, "seconds (0 = automatic backoff)" };
    }
};


/* A settings pane the human opened on purpose: movable modal, not an
   alert. Alerts are for things going wrong. */
resource 'DLOG' (301) {
    {120, 140, 268, 580},
    movableDBoxProc,
    invisible,
    noGoAway,
    0,
    301,
    "File Sharing",
    centerMainScreen
};

resource 'DITL' (301) {
    {
        /* 1 Done   */ {112, 350, 132, 420}, Button { enabled, "Done" };
        /* 2 Choose */ {112, 230, 132, 336},
            Button { enabled, "Choose..." };
        /* 3 label  */ {16, 20, 34, 420},
            StaticText { disabled,
                "The host can browse this folder and everything in it:" };
        /* 4 root   */ {40, 20, 74, 420}, StaticText { disabled, "" };
        /* 5 note   */ {80, 20, 100, 420},
            StaticText { disabled,
                "Nothing outside it is reachable over the wire." };
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
