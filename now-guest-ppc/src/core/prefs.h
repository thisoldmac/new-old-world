#ifndef NOW_PREFS_H
#define NOW_PREFS_H

#include <Carbon.h>

/* On-disk room for the sidebar's module order. Fixed forever at a size
   with headroom, because the record is accretive: growing it later would
   move every field after it. Eleven nav rows use it today. */
enum { kNowSidebarOrderMax = 24 };

/* A project identity is 32 lower-case hex characters; the cap is that
   plus its terminator, stated here because the record's layout depends
   on it and every later field sits after it. */
enum { kNowProjectIDCap = 33 };

typedef struct {
    char host[64];            /* dotted quad, C string */
    unsigned short port;

    /* screenshot tuning (the panel's settings; commands inherit them) */
    short shot_depth;         /* 1/2/4/8/16/32, default 8 */
    Boolean shot_pack;        /* compress on the wire (PackBits), default on */
    short chunk_kb;           /* bulk chunk size in KB, 1..32, default 8 */
    short pace_ms;            /* inter-chunk pacing, default 0 (Orinoco) */

    /* File share identity. A directory ID is stable on its volume and
       needs no path parsing; the path string is only a human label,
       rebuilt best-effort for display. Empty volume = boot volume root. */
    char share_vol[32];       /* volume name */
    long share_dir;           /* directory ID; 0 = the volume root */
    char share_root[128];     /* display label only, never resolved */

    /* Share the whole boot volume instead of the chosen folder. The
       chosen folder stays remembered, so turning this off restores it
       rather than making the human find it again. */
    Boolean share_boot;

    /* Where files pulled from the host land. Same volume+dirID identity
       as the share; empty/0 = the Desktop folder. */
    char dl_vol[32];
    long dl_dir;

    /* stream capture policies (experimental; applied at stream start) */
    Boolean predictive;       /* read only predicted-dirty rows + sweep */
    Boolean interlace;        /* alternate decimated fields */

    /* reconnect cadence: 0 = adaptive backoff (2s doubling to 30s),
       else a fixed retry every N seconds */
    short retry_secs;

    /* The v3 record also carried which of the five old windows were
       open and where they sat. Those windows are gone (one Workshop
       window now), so the fields are read at load only - a set
       console_open seeds the Workshop's Console page - and are not
       exposed here. Their SLOTS remain in the on-disk record, because
       the format is accretive and every later version is layered on
       top of v3. */

    /* Console appearance: black-on-white unless inverted. Persisted by
       the Console surface; carried here so the record has one shape. */
    Boolean console_invert;

    /* Whether launching the app dials the saved target by itself. Off
       means the Workshop's Connection page is the only dialer. */
    Boolean auto_connect;

    /* Whether the log also reaches the now-logs file, not only the
       in-memory ring. On by default: a crash keeps only what reached the
       disk, which is the whole reason the log exists. The Logs page owns
       the switch. */
    Boolean log_to_disk;

    /* Logs page appearance: black-on-white unless inverted, the same
       switch the Console page carries and kept separate from it. */
    Boolean logs_invert;
    short log_retention;       /* recognized launch logs kept, default 10 */

    /* Workshop session: which module was selected, and where the window
       sat. Empty rect = the standard centered bounds. */
    short workshop_module;
    Rect workshop_rect;

    /* Whether an agent may drive this Mac, and how far: the AgentAccessTier
       the MCP page sets and `hello.agent` carries. Read and written only
       through agent_access.c, which is the one place that decides - a
       second reader here would be the second source of truth the plan
       names as its stop condition. A file written before the field existed
       has no opinion and keeps the default (full), because that is what
       every deployed machine already does. */
    short agent_access;

    /* Sidebar appearance and arrangement, owned by the Preferences page.

       sidebar_order holds NAV module ids in the person's order, padded
       with zeros. It is stored raw and sanitised by workshop_sidebar.c,
       the way agent_access is stored raw and judged by agent_access.c -
       prefs is below the seam that owns the id list. Sanitising means an
       unknown id is dropped and a missing one appended, so a module added
       later simply arrives at the foot of a saved order instead of
       invalidating it.

       Nav ids are safe to persist because a new page is APPENDED to the
       nav range; only the pinned ids at the foot have ever been
       renumbered, and those are not in here. */
    short sidebar_order[kNowSidebarOrderMax];
    Boolean sidebar_compact;  /* one line per row instead of icon + two */
    /* Collapsed to icons only. Separate from the density rather than a
       third value of it: collapsing and then expanding must give back
       the density the person chose, not forget it. */
    Boolean sidebar_collapsed;

    /* Mirror observation policy, owned by the Mirror page and enforced at
       each operation's guest-side boundary. These are four independent
       permissions rather than one broad switch because passive anchor
       capture, Finder AppleScript, QuickDraw tracing and SetFrontProcess
       have materially different risk. */
    Boolean mirror_structure;
    Boolean mirror_finder_complements;
    Boolean mirror_content;
    Boolean mirror_foreground_cycle;

    /* Development roots are chosen on this Mac. The display path is never
       resolved as authority; the volume/ref pair and directory ID are the
       identity used by the project and toolchain services. */
    short projects_vref;
    long projects_dir;
    char projects_root[128];
    short toolchain_vref;
    long toolchain_dir;
    char toolchain_root[128];
    Boolean toolchain_qualified;

    /* Web is a direct connection to the host listener in the pre-alpha.
       The address deliberately remains the Connection page's host: on
       QEMU that is 10.0.2.2, while hardware needs the host Mac's LAN
       address. A separate address here would let the two silently drift. */
    unsigned short web_proxy_port;
    short web_profile;        /* NowWebProfile; stored raw, model sanitizes */
    short web_lens;           /* NowWebLens; stored raw, model sanitizes */

    /* An Extension exchange is complete before its resident code can be.
       Keep the full release identity across application relaunches; startup
       clears it only after the active table reports the same 160-bit prefix. */
    char pending_extension_build[65];

    /* CarbonLib warnings are advisory and may be dismissed permanently on a
       machine whose owner has deliberately chosen an older runtime. */
    Boolean carbon_warning_suppressed;

    /* Whether the Workshop was open the last time this session ended,
       user-close and quit teardown both write it (workshop_close's
       'quitting' argument tells them apart) so a deliberate close stays
       closed across relaunch and an open window comes back. Default true:
       every existing machine already sees it open at launch, and a file
       that predates the field must not change that. */
    Boolean workshop_open_at_quit;

    /* Which project this Mac is working on, as the opaque identity the
       Projects walk mints - not a folder reference. A project that has
       been renamed, moved within the root or deleted costs one failed
       lookup, where a stored vRefNum/dirID would quietly point at
       whatever occupies that directory next. Empty means none chosen,
       which is what a file predating the field says and what a machine
       with a fresh Projects root means. */
    char active_project_id[kNowProjectIDCap];
} NowPrefs;

/* Loads saved settings, or the defaults (10.0.2.2:5250 — the QEMU host
   address — 8-bit, pack on, 8K chunks, no pacing, panel open). Reads the
   v1/v2 record formats (host/port only) through v11 (the v9 layout,
   twice-renumbered for Processes and Hardware), v12 (adds log_to_disk
   and renumbers Connection again for the Logs page), v13/v14, v15
   (adds agent_access and renumbers for the MCP and Diagnostics pages),
   v16/v17 (no new fields; Networking then iCloud renumber the pinned
   pair), v18 (Chat, likewise), and v19 (adds the sidebar order and
   density, and renumbers the pinned group again for the Preferences
   page), v20 (the collapsed sidebar), v21 (Mirror's module-id
   renumbering), v22 (the four Mirror policy domains), and v23
   (Development roots plus its module-id renumbering), and v24 (Web's port,
   browser profile and lens plus its module-id renumbering), and v25
   (shared guest-log retention count), v26 (pending Extension activation
   identity and the CarbonLib warning choice), and v27 (whether the
   Workshop was open when the session last ended), and v28 (the chosen
   active project's opaque identity). */
void now_prefs_load(NowPrefs *prefs);
OSErr now_prefs_save(const NowPrefs *prefs);

#endif
