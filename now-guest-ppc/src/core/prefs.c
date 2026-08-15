#include "prefs.h"

#include <string.h>

#include "contract.h"
#include "product_identity.h"
#include "log_retention.h"
/* The one place the four retired Mirror gates collapse into the master
   consent. Toolbox-free and shared with the wire, so this migration and
   the compatibility fields cannot drift apart. */
#include "mirror_consent.h"

#define kPrefsMagic 'NOWp'

typedef struct {
    OSType magic;
    short format;
    unsigned short port;
    char host[64];
} PrefsRecordV1;                      /* v2 appended window data; both read
                                         only for host/port now */

typedef struct {
    OSType magic;
    short format;                     /* 3 */
    unsigned short port;
    char host[64];
    short shot_depth;
    short shot_pack;
    short chunk_kb;
    short pace_ms;
    short panel_open;
    short console_open;
    Rect panel_rect;
    Rect console_rect;
} PrefsRecordV3;

typedef struct {
    PrefsRecordV3 v3;                 /* format = 4 */
    short retry_secs;
} PrefsRecordV4;

typedef struct {
    PrefsRecordV4 v4;                 /* format = 5 */
    short predictive;
    short interlace;
} PrefsRecordV5;

typedef struct {
    PrefsRecordV5 v5;                 /* format = 6 */
    char share_root[128];
} PrefsRecordV6;

typedef struct {
    PrefsRecordV6 v6;                 /* format = 7 */
    char share_vol[32];
    long share_dir;
} PrefsRecordV7;

typedef struct {
    PrefsRecordV7 v7;                 /* format = 8 */
    short share_boot;
    char dl_vol[32];
    long dl_dir;
} PrefsRecordV8;

typedef struct {
    PrefsRecordV8 v8;                 /* format = 9 */
    short console_invert;
    short auto_connect;
    short workshop_module;
    Rect workshop_rect;
} PrefsRecordV9;

/* Formats 10 and 11 reused the V9 layout, bumping only the number to mark
   what a module id MEANS. Format 12 is the first since 9 to add a field,
   so it is a real new layout on top of V9. */
typedef struct {
    PrefsRecordV9 v9;                 /* format = 12 */
    short log_to_disk;
} PrefsRecordV12;

typedef struct {
    PrefsRecordV12 v12;               /* format = 13 */
    short logs_invert;
} PrefsRecordV13;
/* Format 14 reuses this V13 layout, bumping only the number to mark that
   Software joined as nav id 6 (Logs and Connection shifted down); it adds
   no persisted field, like formats 10 and 11 before it. */

/* Format 15: MCP and Diagnostics joined as nav ids 7 and 8, and the MCP
   page's answer is the first field since 13. Both changes in one bump
   because they ship together; the renumber is handled beside the earlier
   ones in now_prefs_load. */
typedef struct {
    PrefsRecordV13 v13;               /* format = 15 */
    short agent_access;
} PrefsRecordV15;

/* Format 19: the Preferences page joins the pinned group, renumbering
   Logs and Connection once more, and brings the first new fields since
   15 - the sidebar's module order and its density. The order is a fixed
   24 shorts so this layout never has to grow again for it. */
typedef struct {
    PrefsRecordV15 v15;               /* format = 19 */
    /* Was the sidebar's density, retired when the rail became
       compact-only. The SLOT stays: this layout is what every format >=
       19 file on disk is, and reclaiming a field would renumber every
       byte after it. Written as zero, never read. */
    short sidebar_density_retired;
    short sidebar_order[kNowSidebarOrderMax];
} PrefsRecordV19;

/* Format 20: the rail can now be collapsed to icons. One more field on
   top of V19, and no renumbering - the collapse button is chrome, not a
   module, so no id moved. */
typedef struct {
    PrefsRecordV19 v19;               /* format = 20 */
    short sidebar_collapsed;
} PrefsRecordV20;

/* Format 21 added the Mirror page and changed only module numbering.
   Format 22 is its first persisted behavior: four independent gates for
   observation strategies with very different safety profiles. */
typedef struct {
    PrefsRecordV20 v20;               /* format = 22 */
    short mirror_structure;
    short mirror_finder_complements;
    short mirror_content;
    short mirror_foreground_cycle;
} PrefsRecordV22;

typedef struct {
    PrefsRecordV22 v22;               /* format = 23 */
    short projects_vref;
    long projects_dir;
    char projects_root[128];
    short toolchain_vref;
    long toolchain_dir;
    char toolchain_root[128];
    short toolchain_qualified;
} PrefsRecordV23;

typedef struct {
    PrefsRecordV23 v23;               /* format = 24 */
    unsigned short web_proxy_port;
    short web_profile;
    short web_lens;
} PrefsRecordV24;

typedef struct {
    PrefsRecordV24 v24;               /* format = 25 */
    short log_retention;
} PrefsRecordV25;

typedef struct {
    PrefsRecordV25 v25;               /* format = 26 */
    char pending_extension_build[65];
    short carbon_warning_suppressed;
} PrefsRecordV26;

typedef struct {
    PrefsRecordV26 v26;               /* format = 27 */
    short workshop_open_at_quit;
} PrefsRecordV27;

/* Format 28: which project this Mac is working on. An identity, not a
   path - the Projects root is already persisted above, and a project is
   found by walking it, so a stale id costs a lookup that fails rather
   than a folder reference that outlives the folder. */
typedef struct {
    PrefsRecordV27 v27;               /* format = 28 */
    char active_project_id[kNowProjectIDCap];
} PrefsRecordV28;

/* Format 29: the four V22 gates collapse into one master consent. The V22
   SLOTS stay where they are and are written from the master (all four
   equal to it), for the same reason sidebar_density_retired stayed:
   reclaiming a field renumbers every byte after it. Writing them rather
   than zeroing them buys one more thing — a file this build saved, read
   back by a format-28 build, grants exactly the permission the master
   granted, because the collapse rule is its own inverse. */
typedef struct {
    PrefsRecordV28 v28;               /* format = 29 */
    short mirror_enabled;
} PrefsRecordV29;

/* Format 16 reuses the V15 layout, bumping only the number to mark that
   Networking joined as nav id 9 (Logs and Connection shifted down
   again). It adds no persisted field, like formats 10, 11 and 14 before
   it - the record is identical and only the id numbering moved. */

/* Preferences are per COPY of the app, not per creator. Running two
   guests at once is a real workflow — one for each host, on different
   ports — and a shared file would have them overwrite each other's port
   and share root. The CANONICAL copy — the shipped product, named
   "New Old World" to match the host app — keeps the base file name so
   nothing already saved is orphaned; any other copy (a dev build called
   "now-guest", a side experiment) gets its own file, named after itself,
   and starts from defaults (which on the emulator means the 10.0.2.2
   gateway). Renaming the canonical binary would therefore lose the
   saved host and look like a hang on metal, so the name is pinned here
   and in the build (now-guest-ppc/tools/name_macbinary.py). */
static OSErr prefs_spec(FSSpec *spec)
{
    ProcessSerialNumber self;
    ProcessInfoRec info;
    Str31 app_name;
    Str255 file_name;
    short vref;
    long dirid;
    OSErr err;

    err = FindFolder(kOnSystemDisk, kPreferencesFolderType,
                     kCreateFolder, &vref, &dirid);
    if (err != noErr) {
        return err;
    }
    BlockMoveData("\pNew Old World Prefs", file_name, 21);

    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processName = app_name;
    app_name[0] = 0;
    if (GetCurrentProcess(&self) == noErr
        && GetProcessInformation(&self, &info) == noErr
        && app_name[0] > 0
        && !EqualString(app_name, (ConstStr255Param)"\pNew Old World",
                        false, false)) {
        long room = 31 - file_name[0] - 3;

        if (app_name[0] < room) {
            room = app_name[0];
        }
        if (room > 0) {
            file_name[file_name[0] + 1] = ' ';
            file_name[file_name[0] + 2] = '(';
            BlockMoveData(app_name + 1, file_name + file_name[0] + 3,
                          room);
            file_name[file_name[0] + 3 + room] = ')';
            file_name[0] = (unsigned char)(file_name[0] + room + 3);
        }
    }
    return FSMakeFSSpec(vref, dirid, file_name, spec);
}

static void set_defaults(NowPrefs *prefs)
{
    memset(prefs, 0, sizeof *prefs);
    strcpy(prefs->host, "10.0.2.2");
    prefs->port = kNowDefaultHostPort;
    /* A capture POLICY, not a reading of this screen: 8-bit is the depth
       worth sending over this wire, whatever the panel happens to be. The
       neighbouring defaults each say why they are what they are and this
       one did not, which left it looking like an assumption that the
       machine is 8-bit — it is not, and a deeper screen is down-sampled on
       purpose. The real depth is read where it matters
       (cloud_preview_well.c :: screen_depth, census_probes.c), and the
       Depth popup is how a person overrides the policy. */
    prefs->shot_depth = 8;
    prefs->shot_pack = true;
    prefs->chunk_kb = 8;
    prefs->pace_ms = 0;
    prefs->console_invert = false;
    /* Dialing on launch is the established behavior; the checkbox on the
       Connection page is how it is turned off. */
    prefs->auto_connect = true;
    /* Persisting to disk is the established behavior and what crash
       survival needs; the Logs page is how it is turned off. A pre-v12
       file has no such field and keeps this default. */
    prefs->log_to_disk = true;
    prefs->logs_invert = false;
    prefs->log_retention = kNowLogRetentionDefault;
    /* Full access is what every deployed machine already does, so a file
       that predates the field keeps it; the MCP page is how it is refused.
       Spelled 2 rather than kAgentAccessFull because prefs.c is below the
       seam that owns the enum - agent_access.c validates what it reads
       here and never trusts this number blind. */
    prefs->agent_access = 2;
    prefs->workshop_module = 1;       /* Screenshots */
    SetRect(&prefs->workshop_rect, 0, 0, 0, 0);
    /* An all-zero order means "no opinion": the sidebar fills it from its
       own curated default, so a file that predates the field - or one
       saved before the default existed - gets the curation rather than a
       half-remembered arrangement. */
    prefs->sidebar_collapsed = false;
    /* This Mac may be mirrored unless somebody says otherwise, which is
       what the four gates it replaces already meant in practice: the one
       that was on by default, structure, is the one without which the
       Mirror shows nothing at all. The three that were off by default were
       granularity, and granularity is the host's now — including the
       drawing trace, which the host must still switch on per machine and
       whose default moved there with it (MirrorPlanePolicyStore). Nothing
       springs to life here that was not already reachable; what changed is
       which side is asked. */
    prefs->mirror_enabled = true;
    prefs->web_proxy_port = 5180;
    prefs->web_profile = 1;            /* Classilla */
    prefs->web_lens = 1;               /* Compatible Page */
    /* Every existing machine already launches with the window open; a
       file that predates the field must keep seeing that, not a closed
       Workshop it never asked for. */
    prefs->workshop_open_at_quit = true;
}

static Boolean valid_depth(short depth)
{
    return depth == 1 || depth == 2 || depth == 4 || depth == 8
        || depth == 16 || depth == 32;
}

void now_prefs_load(NowPrefs *prefs)
{
    FSSpec spec;
    short ref;
    long count = sizeof(PrefsRecordV29);
    PrefsRecordV29 v29;
    PrefsRecordV28 v28;
    PrefsRecordV27 v27;
    PrefsRecordV26 v26;
    PrefsRecordV25 v25;
    PrefsRecordV24 v24;
    PrefsRecordV23 v23;
    PrefsRecordV22 v22;
    PrefsRecordV20 v20;
    PrefsRecordV19 v19;
    PrefsRecordV15 v15;
    PrefsRecordV13 v13;
    PrefsRecordV12 v12;
    PrefsRecordV9 v9;
    PrefsRecordV3 record;
    OSErr err;

    set_defaults(prefs);
    err = prefs_spec(&spec);
    if (err != noErr && err != fnfErr) {
        return;
    }
    if (FSpOpenDF(&spec, fsRdPerm, &ref) != noErr) {
        return;
    }
    memset(&v29, 0, sizeof v29);
    err = FSRead(ref, &count, &v29);
    FSClose(ref);
    v28 = v29.v28;
    v27 = v28.v27;
    v26 = v27.v26;
    v25 = v26.v25;
    v24 = v25.v24;
    v23 = v24.v23;
    v22 = v23.v22;
    v20 = v22.v20;
    v19 = v20.v19;
    v15 = v19.v15;
    v13 = v15.v13;
    v12 = v13.v12;
    v9 = v12.v9;
    record = v9.v8.v7.v6.v5.v4.v3;
    if ((err != noErr && err != eofErr)
        || record.magic != kPrefsMagic || record.port == 0) {
        return;
    }
    record.host[sizeof record.host - 1] = '\0';
    strcpy(prefs->host, record.host);
    prefs->port = record.port;
    if (record.format < 3
        || count < (long)sizeof(PrefsRecordV3)) {
        return;                       /* v1/v2: connection only, rest default */
    }
    if (valid_depth(record.shot_depth)) {
        prefs->shot_depth = record.shot_depth;
    }
    prefs->shot_pack = record.shot_pack != 0;
    if (record.chunk_kb >= 1 && record.chunk_kb <= 32) {
        prefs->chunk_kb = record.chunk_kb;
    }
    if (record.pace_ms >= 0 && record.pace_ms <= 100) {
        prefs->pace_ms = record.pace_ms;
    }
    if (record.format >= 4 && count >= (long)sizeof(PrefsRecordV4)
        && v9.v8.v7.v6.v5.v4.retry_secs >= 0 && v9.v8.v7.v6.v5.v4.retry_secs <= 300) {
        prefs->retry_secs = v9.v8.v7.v6.v5.v4.retry_secs;
    }
    if (record.format >= 5 && count >= (long)sizeof(PrefsRecordV5)) {
        prefs->predictive = v9.v8.v7.v6.v5.predictive != 0;
        prefs->interlace = v9.v8.v7.v6.v5.interlace != 0;
    }
    if (record.format >= 6 && count >= (long)sizeof(PrefsRecordV6)) {
        v9.v8.v7.v6.share_root[sizeof v9.v8.v7.v6.share_root - 1] = '\0';
        strcpy(prefs->share_root, v9.v8.v7.v6.share_root);
    }
    if (record.format >= 7 && count >= (long)sizeof(PrefsRecordV7)) {
        v9.v8.v7.share_vol[sizeof v9.v8.v7.share_vol - 1] = '\0';
        strcpy(prefs->share_vol, v9.v8.v7.share_vol);
        prefs->share_dir = v9.v8.v7.share_dir;
    }
    if (record.format >= 8 && count >= (long)sizeof(PrefsRecordV8)) {
        prefs->share_boot = v9.v8.share_boot != 0;
        v9.v8.dl_vol[sizeof v9.v8.dl_vol - 1] = '\0';
        strcpy(prefs->dl_vol, v9.v8.dl_vol);
        prefs->dl_dir = v9.v8.dl_dir;
    }
    if (record.format >= 9 && count >= (long)sizeof(PrefsRecordV9)) {
        short module = v9.workshop_module;

        prefs->console_invert = v9.console_invert != 0;
        prefs->auto_connect = v9.auto_connect != 0;
        /* Each new page renumbered the ones below it, and Connection —
           pinned last — moved every time: Processes made it 4 -> 5,
           Hardware 5 -> 6, Logs 6 -> 7. The layout is unchanged; the bump
           only marks what the number MEANS, so an old file reopens on the
           page the person actually had. Only Connection ever moved, so
           only the id that meant Connection is remapped, to its id now. */
        if (record.format == 9 && module == 4) {
            module = 7;
        }
        if (record.format == 10 && module == 5) {
            module = 7;
        }
        if (record.format == 11 && module == 6) {
            module = 7;
        }
        /* Software went in as id 6 (the last nav row), pushing Logs 6 -> 7
           and Connection 7 -> 8. After the remaps above, any pre-14 file
           speaks the old numbering, where 6 meant Logs and 7 meant
           Connection; lift both. This is the first insert to move an
           EXISTING non-pinned id (Logs), not just the pinned Connection,
           so it remaps two values, Connection first to avoid 6->7->8. */
        if (record.format <= 13) {
            if (module == 7) {
                module = 8;           /* Connection */
            } else if (module == 6) {
                module = 7;           /* Logs */
            }
        }
        /* MCP and Diagnostics went in as ids 7 and 8, pushing Logs 7 -> 9
           and Connection 8 -> 10. After the lift above, any pre-15 file is
           speaking the format-14 numbering, so both move again - Connection
           first, so 7 -> 9 cannot then run on into 10. */
        if (record.format <= 14) {
            if (module == 8) {
                module = 10;          /* Connection */
            } else if (module == 7) {
                module = 9;           /* Logs */
            }
        }
        /* Networking went in as id 9 (the last nav row), pushing Logs
           9 -> 10 and Connection 10 -> 11. Same shape as the two inserts
           above and the same ordering trap: Connection moves first, so
           9 -> 10 cannot then run on into 11. */
        if (record.format <= 15) {
            if (module == 10) {
                module = 11;          /* Connection */
            } else if (module == 9) {
                module = 10;          /* Logs */
            }
        }
        /* iCloud went in as id 10 (the last nav row), pushing Logs
           10 -> 11 and Connection 11 -> 12. Same shape, same ordering
           trap: Connection moves first, so 10 -> 11 cannot then run on
           into 12. */
        if (record.format <= 16) {
            if (module == 11) {
                module = 12;          /* Connection */
            } else if (module == 10) {
                module = 11;          /* Logs */
            }
        }
        if (record.format <= 17) {
            /* Chat went in as nav id 11 (format 18), pushing the
               pinned pair down one more. */
            if (module == 12) {
                module = 13;          /* Connection */
            } else if (module == 11) {
                module = 12;          /* Logs */
            }
        }
        if (record.format <= 18) {
            /* Preferences went in as the FIRST of the pinned group
               (format 19), so both the pages below it move: Logs 12 -> 13
               and Connection 13 -> 14. Connection first, as ever, or
               12 -> 13 runs straight on into 14. */
            if (module == 13) {
                module = 14;          /* Connection */
            } else if (module == 12) {
                module = 13;          /* Logs */
            }
        }
        if (record.format <= 20) {
            /* Mirror went in as nav id 12 (format 21; 20 was the rail's
               collapsed state and renumbered nothing), pushing the whole
               pinned group down: Preferences 12 -> 13, Logs 13 -> 14,
               Connection 14 -> 15. Deepest first, as ever. A format-18
               file from a Mirror-branch rig clone reads as Chat-era here
               and lands one row off; those files never left throwaway
               clones, and the trade is recorded in the merge that made
               main's numbering canonical. */
            if (module == 14) {
                module = 15;          /* Connection */
            } else if (module == 13) {
                module = 14;          /* Logs */
            } else if (module == 12) {
                module = 13;          /* Preferences */
            }
        }
        if (record.format <= 22) {
            if (module == 15) {
                module = 16;          /* Connection */
            } else if (module == 14) {
                module = 15;          /* Logs */
            } else if (module == 13) {
                module = 14;          /* Preferences */
            }
        }
        if (record.format <= 23) {
            /* Web is appended to the nav range, so only the pinned group
               moves: Preferences 14 -> 15, Logs 15 -> 16 and Connection
               16 -> 17. Deepest first prevents a remap from being remapped
               again by the next comparison. */
            if (module == 16) {
                module = 17;          /* Connection */
            } else if (module == 15) {
                module = 16;          /* Logs */
            } else if (module == 14) {
                module = 15;          /* Preferences */
            }
        }
        /* 17 rather than kWorkshopModuleCount: prefs is core and the
           module id list is UI, so this file does not include the
           Workshop's header. The number is a literal here for the same
           reason it always was, and the remaps above are what keep it
           meaningful. */
        if (module >= 1 && module <= 17) {
            prefs->workshop_module = module;
        }
        prefs->workshop_rect = v9.workshop_rect;
        if (record.format >= 12 && count >= (long)sizeof(PrefsRecordV12)) {
            prefs->log_to_disk = v12.log_to_disk != 0;
        }
        if (record.format >= 13 && count >= (long)sizeof(PrefsRecordV13)) {
            prefs->logs_invert = v13.logs_invert != 0;
        }
        if (record.format >= 15 && count >= (long)sizeof(PrefsRecordV15)) {
            /* Stored raw; agent_access.c is what validates it, because it
               is the one place that decides what an unreadable answer
               means. A pre-15 file keeps the default. */
            prefs->agent_access = v15.agent_access;
        }
        if (record.format >= 19 && count >= (long)sizeof(PrefsRecordV19)) {
            /* Stored raw, sanitised by the sidebar: this file does not
               know which ids are nav rows, and a half-validated order
               would be a second opinion about the same list. */
            memcpy(prefs->sidebar_order, v19.sidebar_order,
                   sizeof prefs->sidebar_order);
        }
        if (record.format >= 20 && count >= (long)sizeof(PrefsRecordV20)) {
            prefs->sidebar_collapsed = v20.sidebar_collapsed != 0;
        }
        if (record.format >= 22 && count >= (long)sizeof(PrefsRecordV22)) {
            /* The four retired gates, collapsed by the one rule that owns
               that collapse. A format-29 record overwrites this below; a
               file written by any build between 22 and 28 is answered
               here, and answered conservatively — consent only where all
               four were on. Almost every such file says no, because only
               structure was ever on by default, and that is the intended
               reading: a person who chose three of four never consented to
               the fourth, and a master switch inferred from a majority
               would be consent this Mac was never asked for. */
            prefs->mirror_enabled = now_mirror_consent_from_gates(
                v22.mirror_structure, v22.mirror_finder_complements,
                v22.mirror_content, v22.mirror_foreground_cycle) != 0;
        }
        if (record.format >= 23 && count >= (long)sizeof(PrefsRecordV23)) {
            prefs->projects_vref = v23.projects_vref;
            prefs->projects_dir = v23.projects_dir;
            strncpy(prefs->projects_root, v23.projects_root,
                    sizeof prefs->projects_root - 1);
            prefs->toolchain_vref = v23.toolchain_vref;
            prefs->toolchain_dir = v23.toolchain_dir;
            strncpy(prefs->toolchain_root, v23.toolchain_root,
                    sizeof prefs->toolchain_root - 1);
            prefs->toolchain_qualified = v23.toolchain_qualified != 0;
        }
        if (record.format >= 24 && count >= (long)sizeof(PrefsRecordV24)) {
            if (v24.web_proxy_port != 0) {
                prefs->web_proxy_port = v24.web_proxy_port;
            }
            prefs->web_profile = v24.web_profile;
            prefs->web_lens = v24.web_lens;
        }
        if (record.format >= 25 && count >= (long)sizeof(PrefsRecordV25)) {
            prefs->log_retention =
                (short)now_log_retention_sanitize(v25.log_retention);
        }
        if (record.format >= 26 && count >= (long)sizeof(PrefsRecordV26)) {
            v26.pending_extension_build[
                sizeof v26.pending_extension_build - 1] = '\0';
            strncpy(prefs->pending_extension_build,
                    v26.pending_extension_build,
                    sizeof prefs->pending_extension_build - 1);
            prefs->carbon_warning_suppressed =
                v26.carbon_warning_suppressed != 0;
        }
        if (record.format >= 27 && count >= (long)sizeof(PrefsRecordV27)) {
            prefs->workshop_open_at_quit = v27.workshop_open_at_quit != 0;
        }
        if (record.format >= 28 && count >= (long)sizeof(PrefsRecordV28)) {
            v28.active_project_id[sizeof v28.active_project_id - 1] = '\0';
            strncpy(prefs->active_project_id, v28.active_project_id,
                    sizeof prefs->active_project_id - 1);
        }
        if (record.format >= 29 && count >= (long)sizeof(PrefsRecordV29)) {
            prefs->mirror_enabled = v29.mirror_enabled != 0;
        }
    } else if (record.console_open != 0) {
        /* Seed from the old window session: someone who kept the
           Console window open wants the Console page, not Screenshots.
           This is the only surviving use of the v3 window fields. */
        prefs->workshop_module = 3;
    }
}

OSErr now_prefs_save(const NowPrefs *prefs)
{
    FSSpec spec;
    short ref;
    long count = sizeof(PrefsRecordV29);
    PrefsRecordV29 v29;
    PrefsRecordV28 v28;
    PrefsRecordV27 v27;
    PrefsRecordV26 v26;
    PrefsRecordV25 v25;
    PrefsRecordV24 v24;
    PrefsRecordV23 v23;
    PrefsRecordV22 v22;
    PrefsRecordV20 v20;
    PrefsRecordV19 v19;
    PrefsRecordV15 v15;
    PrefsRecordV13 v13;
    PrefsRecordV12 v12;
    PrefsRecordV9 v9;
    PrefsRecordV3 record;
    OSErr err;

    memset(&record, 0, sizeof record);
    record.magic = kPrefsMagic;
    record.format = 29;               /* one master Mirror consent */
    record.port = prefs->port;
    strncpy(record.host, prefs->host, sizeof record.host - 1);
    record.shot_depth = prefs->shot_depth;
    record.shot_pack = prefs->shot_pack ? 1 : 0;
    record.chunk_kb = prefs->chunk_kb;
    record.pace_ms = prefs->pace_ms;
    /* The v3 window-session slots stay zero: the windows they described
       no longer exist, and the record is memset above. */

    err = prefs_spec(&spec);
    if (err != noErr && err != fnfErr) {
        return err;
    }
    err = FSpCreate(&spec, PRODUCT_CREATOR_CODE, 'pref', smSystemScript);
    if (err != noErr && err != dupFNErr) {
        return err;
    }
    err = FSpOpenDF(&spec, fsRdWrPerm, &ref);
    if (err != noErr) {
        return err;
    }
    memset(&v9, 0, sizeof v9);
    v9.v8.v7.v6.v5.v4.v3 = record;
    v9.v8.v7.v6.v5.v4.retry_secs = prefs->retry_secs;
    v9.v8.v7.v6.v5.predictive = prefs->predictive ? 1 : 0;
    v9.v8.v7.v6.v5.interlace = prefs->interlace ? 1 : 0;
    strncpy(v9.v8.v7.v6.share_root, prefs->share_root,
            sizeof v9.v8.v7.v6.share_root - 1);
    strncpy(v9.v8.v7.share_vol, prefs->share_vol,
            sizeof v9.v8.v7.share_vol - 1);
    v9.v8.v7.share_dir = prefs->share_dir;
    v9.v8.share_boot = prefs->share_boot ? 1 : 0;
    strncpy(v9.v8.dl_vol, prefs->dl_vol, sizeof v9.v8.dl_vol - 1);
    v9.v8.dl_dir = prefs->dl_dir;
    v9.console_invert = prefs->console_invert ? 1 : 0;
    v9.auto_connect = prefs->auto_connect ? 1 : 0;
    v9.workshop_module = prefs->workshop_module;
    v9.workshop_rect = prefs->workshop_rect;
    memset(&v12, 0, sizeof v12);
    v12.v9 = v9;
    v12.log_to_disk = prefs->log_to_disk ? 1 : 0;
    memset(&v13, 0, sizeof v13);
    v13.v12 = v12;
    v13.logs_invert = prefs->logs_invert ? 1 : 0;
    memset(&v15, 0, sizeof v15);
    v15.v13 = v13;
    v15.agent_access = prefs->agent_access;
    memset(&v19, 0, sizeof v19);
    v19.v15 = v15;
    v19.sidebar_density_retired = 0;
    memcpy(v19.sidebar_order, prefs->sidebar_order,
           sizeof v19.sidebar_order);
    memset(&v20, 0, sizeof v20);
    v20.v19 = v19;
    v20.sidebar_collapsed = prefs->sidebar_collapsed ? 1 : 0;
    memset(&v22, 0, sizeof v22);
    v22.v20 = v20;
    /* The retired slots, written from the master rather than zeroed. A
       format-28 build reading this file collapses them straight back to
       the same answer; zeroes would have read as "everything refused". */
    v22.mirror_structure =
        (short)now_mirror_consent_to_gates(prefs->mirror_enabled);
    v22.mirror_finder_complements = v22.mirror_structure;
    v22.mirror_content = v22.mirror_structure;
    v22.mirror_foreground_cycle = v22.mirror_structure;
    memset(&v23, 0, sizeof v23);
    v23.v22 = v22;
    v23.projects_vref = prefs->projects_vref;
    v23.projects_dir = prefs->projects_dir;
    strncpy(v23.projects_root, prefs->projects_root,
            sizeof v23.projects_root - 1);
    v23.toolchain_vref = prefs->toolchain_vref;
    v23.toolchain_dir = prefs->toolchain_dir;
    strncpy(v23.toolchain_root, prefs->toolchain_root,
            sizeof v23.toolchain_root - 1);
    v23.toolchain_qualified = prefs->toolchain_qualified ? 1 : 0;
    memset(&v24, 0, sizeof v24);
    v24.v23 = v23;
    v24.web_proxy_port = prefs->web_proxy_port;
    v24.web_profile = prefs->web_profile;
    v24.web_lens = prefs->web_lens;
    memset(&v25, 0, sizeof v25);
    v25.v24 = v24;
    v25.log_retention =
        (short)now_log_retention_sanitize(prefs->log_retention);
    memset(&v26, 0, sizeof v26);
    v26.v25 = v25;
    strncpy(v26.pending_extension_build, prefs->pending_extension_build,
            sizeof v26.pending_extension_build - 1);
    v26.carbon_warning_suppressed =
        prefs->carbon_warning_suppressed ? 1 : 0;
    memset(&v27, 0, sizeof v27);
    v27.v26 = v26;
    v27.workshop_open_at_quit = prefs->workshop_open_at_quit ? 1 : 0;
    memset(&v28, 0, sizeof v28);
    v28.v27 = v27;
    strncpy(v28.active_project_id, prefs->active_project_id,
            sizeof v28.active_project_id - 1);
    memset(&v29, 0, sizeof v29);
    v29.v28 = v28;
    v29.mirror_enabled = prefs->mirror_enabled ? 1 : 0;
    err = FSWrite(ref, &count, &v29);
    if (err == noErr) {
        SetEOF(ref, count);           /* what we wrote, not an older record */
    }
    FSClose(ref);
    return err;
}
