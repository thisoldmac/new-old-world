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

/* Finder's Get Info version, and what a version-checking installer or
   deploy script reads. It was absent, so the Finder showed this app with
   no version at all - and "is the machine running the build I just sent?"
   had only the in-app build stamp to answer it. Kept in step with
   PRODUCT_VERSION in src/product_identity.h (0.1.0); BCD 0x00,0x10 is
   major 0, minor 1, bugfix 0. */
resource 'vers' (1) {
    0x00, 0x10,
    release, 0x00,
    verUS,
    "0.1.0",
    "0.1.0, New Old World"
};

/* The 16x16 small icon. Only ICN# existed, so every Finder list view, the
   application menu and the about-to-switch bar had to shrink the 32x32 -
   which on a 1-bit icon means dropping every other row and column, and
   this design is a one-pixel frame, so half of it disappeared. Drawn at
   its real size instead: same outer frame, same centred inner box.

   Mask is the solid silhouette, not a copy of the art: it is what the
   Finder fills for the selected state. */
resource 'ics#' (128) {
    {
        $"0000 7FFE 4002 4002 4002 4FF2 4812 4812"
        $"4FF2 4002 4002 4002 4002 7FFE 0000 0000",
        $"0000 7FFE 7FFE 7FFE 7FFE 7FFE 7FFE 7FFE"
        $"7FFE 7FFE 7FFE 7FFE 7FFE 7FFE 0000 0000"
    }
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

/* The Workshop sidebar's module icons, 16x16 1-bit with solid-silhouette
   masks, same rules as ics#(128): drawn at their real size, one-pixel
   art, mask is what the system fills for a selected state.
   129 camera (Screenshots), 130 folder (Files), 131 terminal (Console),
   132 globe (Connection). */
resource 'ics#' (129) {
    {
        $"0000 0000 0780 7FFE 4002 43C2 4422 4812"
        $"4812 4422 43C2 4002 7FFE 0000 0000 0000",
        $"0000 0000 0780 7FFE 7FFE 7FFE 7FFE 7FFE"
        $"7FFE 7FFE 7FFE 7FFE 7FFE 0000 0000 0000"
    }
};

resource 'ics#' (130) {
    {
        $"0000 0000 0000 3E00 7FFE 4002 4002 4002"
        $"4002 4002 4002 4002 7FFE 0000 0000 0000",
        $"0000 0000 0000 3E00 7FFE 7FFE 7FFE 7FFE"
        $"7FFE 7FFE 7FFE 7FFE 7FFE 0000 0000 0000"
    }
};

resource 'ics#' (131) {
    {
        $"0000 0000 7FFE 4002 4802 4402 4202 4402"
        $"4802 4002 40F2 4002 7FFE 0000 0000 0000",
        $"0000 0000 7FFE 7FFE 7FFE 7FFE 7FFE 7FFE"
        $"7FFE 7FFE 7FFE 7FFE 7FFE 0000 0000 0000"
    }
};

resource 'ics#' (132) {
    {
        $"0000 0000 07E0 1998 2184 4182 4182 7FFE"
        $"4182 4182 2184 1998 07E0 0000 0000 0000",
        $"0000 0000 07E0 1FF8 3FFC 7FFE 7FFE 7FFE"
        $"7FFE 7FFE 3FFC 1FF8 07E0 0000 0000 0000"
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
        /* 7 */ {24, 20, 40, 100}, StaticText { disabled, "Address:" };
        /* 8 */ {54, 20, 70, 100}, StaticText { disabled, "Port:" };
        /* 9 retry */ {84, 110, 100, 160}, EditText { enabled, "" };
        /* 10 */ {84, 20, 100, 100}, StaticText { disabled, "Retry:" };
        /* 11 */ {84, 170, 100, 400},
            StaticText { disabled, "seconds (0 = automatic backoff)" };
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
