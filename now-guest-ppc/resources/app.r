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

/* The application icon family — 'ICN#', 'ics#' and their four colour
   siblings — lives in assets/icons/classic/now-icons.r, which this target
   Rez'es alongside this file. It used to be two hand-written 1-bit
   resources here: a one-pixel frame, drawn at 32 and again at 16 so the
   small size would not be a decimated copy of the large one.

   They are gone rather than kept as a fallback, because Rez'ing two
   definitions of 'ICN#' (128) is a duplicate-resource error, not a
   precedence rule. The BNDL above still points at { 'ICN#', 128 } and
   still resolves — the family simply arrives from the other file now, and
   with four more depths than a hand-written one could carry.

   The ics# resources BELOW this comment are a different thing entirely:
   the Workshop's own module icons at 129 and up. They stay. */

/* The Workshop sidebar's module icons, 16x16 1-bit with solid-silhouette
   masks, same rules as ics#(128): drawn at their real size, one-pixel
   art, mask is what the system fills for a selected state.
   129 camera (Screenshots), 130 folder (Files), 131 terminal (Console),
   132 globe (Connection), 133 row list (Processes), 134 chip (Hardware),
   135 lined page (Logs), 136 boxed app tiles (Software), 137 key (MCP),
   138 gauge (Diagnostics), 139 linked nodes (Networking),
   140 cloud (iCloud), 141 speech bubble (Chat),
   142 sliders (Preferences). */
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

/* 133: a framed list of rows - the process list (Processes). */
resource 'ics#' (133) {
    {
        $"0000 7FFE 4002 5FFA 4002 5FFA 4002 5FFA"
        $"4002 5FFA 4002 5FFA 4002 7FFE 0000 0000",
        $"0000 7FFE 7FFE 7FFE 7FFE 7FFE 7FFE 7FFE"
        $"7FFE 7FFE 7FFE 7FFE 7FFE 7FFE 0000 0000"
    }
};

/* 134 chip (Hardware): a die with pins on all four sides. */
resource 'ics#' (134) {
    {
        $"0000 0490 0490 1FF8 1008 700E 1008 1188"
        $"718E 1188 1008 700E 1FF8 0490 0490 0000",
        $"0000 0490 0490 1FF8 1FF8 7FFE 1FF8 1FF8"
        $"7FFE 1FF8 1FF8 7FFE 1FF8 0490 0490 0000"
    }
};

/* 135 lined page (Logs): a document outline with text lines of varying
   length inside - distinct from 133's full-width table. */
resource 'ics#' (135) {
    {
        $"0000 1FF8 1008 1008 17E8 1008 17C8 1008"
        $"17E8 1008 1788 1008 1008 1FF8 0000 0000",
        $"0000 1FF8 1FF8 1FF8 1FF8 1FF8 1FF8 1FF8"
        $"1FF8 1FF8 1FF8 1FF8 1FF8 1FF8 0000 0000"
    }
};

/* 136 boxed app tiles (Software): a container holding three rows of two
   application squares - "what is installed" - distinct from 133's table,
   134's chip, and 135's lined document. */
resource 'ics#' (136) {
    {
        $"0000 1FF8 1008 1668 1668 1008 1668 1668"
        $"1008 1668 1668 1008 1FF8 0000 0000 0000",
        $"0000 1FF8 1FF8 1FF8 1FF8 1FF8 1FF8 1FF8"
        $"1FF8 1FF8 1FF8 1FF8 1FF8 0000 0000 0000"
    }
};

/* 137 key (MCP): a ring on the left with a toothed shaft running right -
   permission, which is the only thing this page decides. Distinct from
   132's globe, which is about reaching the other Mac rather than about
   who may reach this one. */
resource 'ics#' (137) {
    {
        $"0000 0000 0000 0000 3800 4400 47FC 4448"
        $"3848 0000 0000 0000 0000 0000 0000 0000",
        $"0000 0000 0000 0000 7C00 7C00 7FFC 7FFC"
        $"7FFC 0000 0000 0000 0000 0000 0000 0000"
    }
};

/* 138 gauge (Diagnostics): a framed dial with a needle - measurement,
   distinct from 134's chip (what this Mac IS) and 133's table. */
resource 'ics#' (138) {
    {
        $"0000 0000 0000 7FFE 4002 4022 4042 4082"
        $"4102 4202 4382 4002 7FFE 0000 0000 0000",
        $"0000 0000 0000 7FFE 7FFE 7FFE 7FFE 7FFE"
        $"7FFE 7FFE 7FFE 7FFE 7FFE 0000 0000 0000"
    }
};

/* 139: Networking. A globe - circle with a meridian and two parallels,
   which reads at 16x16 where a plug or a cable does not. */
resource 'ics#' (139) {
    {
        $"0000 07E0 1818 2424 4426 4A22 9241 9241"
        $"9241 4A22 4426 2424 1818 07E0 0000 0000",
        $"0000 07E0 1FF8 3FFC 7FFE 7FFE FFFF FFFF"
        $"FFFF 7FFE 7FFE 3FFC 1FF8 07E0 0000 0000"
    }
};

resource 'ics#' (140) {
    {
        $"0000 0000 0000 03C0 0C30 1008 2004 4002"
        $"8001 8001 8001 4002 3FFC 0000 0000 0000",
        $"0000 0000 0000 03C0 0FF0 1FF8 3FFC 7FFE"
        $"FFFF FFFF FFFF 7FFE 3FFC 0000 0000 0000"
    }
};

/* Chat: a speech balloon, tail toward the sidebar text. */
resource 'ics#' (141) {
    {
        $"0000 0000 0FF8 1004 2002 2492 2002 1004"
        $"0FF8 00E0 00C0 0080 0000 0000 0000 0000",
        $"0000 0000 0FF8 1FFC 3FFE 3FFE 3FFE 1FFC"
        $"0FF8 00E0 00C0 0080 0000 0000 0000 0000"
    }
};

/* 142 sliders (Preferences). Three tracks with their knobs at different
   settings - the era's own icon for "settings", and legible at 16 in one
   bit, which a gear is not. Mask equals the art here rather than filling
   a silhouette: this is line art with deliberate gaps, and a solid mask
   would punch a white block out of the selection band. */
resource 'ics#' (142) {
    {
        $"0000 0000 0E00 3FFC 0E00 0000 0070 3FFC"
        $"0070 0000 0700 3FFC 0700 0000 0000 0000",
        $"0000 0000 0E00 3FFC 0E00 0000 0070 3FFC"
        $"0070 0000 0700 3FFC 0700 0000 0000 0000"
    }
};

/* 143: Mirror. A framed pane with a diagonal highlight across it - the
   glancing reflection a mirror or a screen shows, and the one shape at
   this size that is not already 138's dial, 135's document or 136's
   tiles. 141 and 142 went to Chat and Preferences in the same merge
   window, so Mirror moved up rather than fight for its old slot. */
resource 'ics#' (143) {
    {
        $"0000 0000 3FFC 200C 2014 2024 2044 2084"
        $"2104 2204 2404 2804 3004 3FFC 0000 0000",
        $"0000 0000 3FFC 3FFC 3FFC 3FFC 3FFC 3FFC"
        $"3FFC 3FFC 3FFC 3FFC 3FFC 3FFC 0000 0000"
    }
};

/* 144: Development. A compact hammer over a project sheet. */
resource 'ics#' (144) {
    {
        $"0000 1800 3C00 1C00 0E00 0700 0380 01C0"
        $"00E0 0070 0038 001C 001E 003F 0000 0000",
        $"0000 3C00 7E00 3E00 1F00 0F80 07C0 03E0"
        $"01F0 00F8 007C 003E 003F 007F 0000 0000"
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

/* The Connection page's address/port editor. A movable-modal DIALOG
   because the Dialog Manager's edit-text items take clicks and keys
   where an Appearance edit-text control does not in this app (see
   conn_edit_dialog.c). Item numbers match the enum there. */
resource 'DLOG' (301) {
    {120, 140, 300, 500},
    movableDBoxProc,
    invisible,
    noGoAway,
    0,
    301,
    "Connection",
    centerMainScreen
};

resource 'DITL' (301) {
    {
        /* 1 Save    */ {144, 274, 164, 344}, Button { enabled, "Save" };
        /* 2 Cancel  */ {144, 190, 164, 260}, Button { enabled, "Cancel" };
        /* 3 addr    */ {22, 96, 38, 344}, EditText { enabled, "" };
        /* 4 port    */ {50, 96, 66, 176}, EditText { enabled, "" };
        /* 5 status  */ {82, 20, 130, 344}, StaticText { disabled, "" };
        /* 6 */ {22, 20, 38, 90}, StaticText { disabled, "Address:" };
        /* 7 */ {50, 20, 66, 90}, StaticText { disabled, "Port:" };
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

/* The Software page's domain pop-up. Item order is load-bearing:
   software_module.c maps items 1-5 to the domain keys in k_domains_ui. */
resource 'MENU' (134) {
    134, textMenuProc, allEnabled, enabled, "Show",
    {
        "Applications", noIcon, noKey, noMark, plain;
        "Extensions", noIcon, noKey, noMark, plain;
        "Control Panels", noIcon, noKey, noMark, plain;
        "Startup Items", noIcon, noKey, noMark, plain;
        "Apple Menu Items", noIcon, noKey, noMark, plain
    }
};

resource 'MENU' (135) {
    135, textMenuProc, allEnabled, enabled, "iCloud",
    {
        "(none)", noIcon, noKey, noMark, plain
    }
};

/* The Photos view's download-size pop-up. Item order is load-bearing:
   cloud_model.c's cloud_size_token maps items 1-4 to the contract's
   four size tokens (original / long1600 / long1024 / long640), largest
   first, and cloud_photos_view.c's k_size_stops maps the same items to
   the longest edge each one asks for.
   There is NO "host default" item any more: an item that cannot say on
   screen what it will deliver is not an answer to "at what size?", so
   the host's own setting arrives as data (cloud.report defaultSize)
   and is preselected instead.
   Each longN stop names the LONGEST edge, which is why the wording
   below says "long side" rather than a box: a 640x480 BOX gave a
   portrait photo the short edge's number. The text is the FALLBACK
   wording only — rebuild_size_menu rewrites every item via
   SetMenuItemText to the selected photo's exact result ("480 x 640")
   whenever the entry states its width/height, and restores this
   literal wording on no selection or when it does not. */
resource 'MENU' (136) {
    136, textMenuProc, allEnabled, enabled, "Size",
    {
        "Original", noIcon, noKey, noMark, plain;
        "Long side 1600", noIcon, noKey, noMark, plain;
        "Long side 1024", noIcon, noKey, noMark, plain;
        "Long side 640", noIcon, noKey, noMark, plain
    }
};

/* The Chat page's model pop-up: a placeholder the catalog rewrites. */
resource 'MENU' (137) {
    137, textMenuProc, allEnabled, enabled, "Models",
    {
        "(ask the other Mac)", noIcon, noKey, noMark, plain
    }
};

/* The Chat page's provider pop-up, rewritten the same way. */
resource 'MENU' (138) {
    138, textMenuProc, allEnabled, enabled, "Providers",
    {
        "(none)", noIcon, noKey, noMark, plain
    }
};

/* The Connection page's Retry pop-up. Item order is load-bearing:
   conn_fields.c maps items 1-4 to 0/2/5/10 seconds. */
resource 'MENU' (133) {
    133, textMenuProc, allEnabled, enabled, "Retry",
    {
        "Automatic backoff", noIcon, noKey, noMark, plain;
        "2 seconds", noIcon, noKey, noMark, plain;
        "5 seconds", noIcon, noKey, noMark, plain;
        "10 seconds", noIcon, noKey, noMark, plain
    }
};
