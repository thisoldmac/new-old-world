#include "commands.h"

#include "act_cmds.h"
#include "desktop.h"
#include "input_cmds.h"
#include "mach_verbs.h"
#include "nowlog.h"
#include "observe.h"
#include "qdtrace.h"
#include "transitions_cmd.h"

#include <Carbon.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "machine_names.h"
#include "capture.h"
#include "census.h"
#include "cmd_help.h"
#include "cmd_line.h"
#include "gestalt_json.h"
#include "json.h"
#include "prefs.h"
#include "fileshare.h"
#include "wire.h"
#include "wirestat_cmd.h"
#include "mirror_json.h"
#include "mirror_probe.h"
#include "net_layout.h"
#include "net_probe.h"
#include "screenshot.h"
#include "vprobe.h"
#include "catsearch.h"
#include "software.h"
#include "proc_actions.h"

const char *const kGestaltFullGroups[] = {
    "cpu", "memory", "os", "network", "hw", NULL
};

/* --- value formatting --------------------------------------------------- */

static void bcd_version(long bcd, char *out, long cap)
{
    long major = ((bcd >> 12) & 0xF) * 10 + ((bcd >> 8) & 0xF);
    long minor = (bcd >> 4) & 0xF;
    long patch = bcd & 0xF;

    if (patch != 0) {
        snprintf(out, cap, "%ld.%ld.%ld", major, minor, patch);
    } else {
        snprintf(out, cap, "%ld.%ld", major, minor);
    }
}

static const char *cpu_name(long type)
{
    switch (type) {
    case 257: return "PowerPC 601";
    case 259: return "PowerPC 603";
    case 262: return "PowerPC 603e";
    case 263: return "PowerPC 603ev";
    case 260: return "PowerPC 604";
    case 265: return "PowerPC 604e";
    case 266: return "PowerPC 604ev";
    case 264: return "PowerPC G3 (750)";
    case 4:   return "68040";
    default:  return NULL;
    }
}

static const char *processor_name(long type)
{
    switch (type) {
    case 1: return "68000";
    case 2: return "68010";
    case 3: return "68020";
    case 4: return "68030";
    case 5: return "68040";
    default: return NULL;
    }
}

static const char *fpu_name(long type)
{
    switch (type) {
    case 0: return "none";
    case 1: return "68881";
    case 2: return "68882";
    case 3: return "68040 (built-in)";
    default: return "present";
    }
}

/* The user-facing model name — sourced from the machine itself, no table.
   1. gestaltUserVisibleMachineName ('mnam') returns a StringPtr with Apple's
      marketing name ("PowerBook 1400cs/117"). Not in Retro68's headers, so
      the selector is spelled inline.
   2. Failing that, the classic machine-name 'STR ' resource, id -16395, that
      the System bakes in.
   3. NOW is metal-forward: on hardware one of the above answers. On the
      emulator neither may, so degrade to the raw machine-type id. */
static void machine_model(char *out, long cap)
{
    long response = 0;
    StringHandle sh;
    long v;
    long n;

    if (Gestalt('mnam', &response) == noErr && response != 0) {
        StringPtr name = (StringPtr)response;
        if (name[0] > 0) {
            n = name[0] < cap - 1 ? name[0] : cap - 1;
            memcpy(out, name + 1, (size_t)n);
            out[n] = '\0';
            return;
        }
    }
    sh = GetString(-16395);
    if (sh != NULL && *sh != NULL && (*sh)[0] > 0) {
        n = (*sh)[0] < cap - 1 ? (*sh)[0] : cap - 1;
        memcpy(out, *sh + 1, (size_t)n);
        out[n] = '\0';
        return;
    }
    /* The classic fleet (a real PowerBook 1400 among them) answers neither
       native mechanism, so fall back to the machineType name table. */
    if (Gestalt(gestaltMachineType, &v) == noErr) {
        int i;
        for (i = 0; i < kNowMachineNameCount; ++i) {
            if (kNowMachineNames[i].id == v) {
                snprintf(out, cap, "%s", kNowMachineNames[i].name);
                return;
            }
        }
        snprintf(out, cap, "Unknown (id %ld)", v);
    } else {
        snprintf(out, cap, "Unknown");
    }
}

/* What to call this machine on the other side's screen.

   The name its owner gave it wins: the File Sharing (Sharing Setup, before
   9) computer name, which the System keeps in 'STR ' -16413 — the same
   string the Chooser and the network show. A machine that was never given
   one degrades to the model, which at least tells a Quadra from a
   PowerBook. The product name is never an answer: every machine running
   NOW would give the same one, which is how both ends came to be called
   "New Old World".

   Two traps, both of which read as working code:
   -16096 is the adjacent resource and a tempting typo, but it is the
   *owner* name — the person, not the machine. And the lookup is scoped to
   the System file with UseResFile(0), because an unscoped GetString starts
   at the current resource file: our own fork answers first if it ever
   carries that id. */
enum { kComputerNameID = -16413 };

void now_machine_name(char *out, long cap)
{
    short saved = CurResFile();
    StringHandle sh;
    long n;

    UseResFile(0);
    sh = GetString(kComputerNameID);
    UseResFile(saved);

    if (sh != NULL && *sh != NULL && (*sh)[0] > 0) {
        n = (*sh)[0] < cap - 1 ? (*sh)[0] : cap - 1;
        memcpy(out, *sh + 1, (size_t)n);
        out[n] = '\0';
        return;
    }
    machine_model(out, cap);
}

/* --- gather ------------------------------------------------------------- */

static void add_row(GestaltRow *rows, int *n, int max, const char *group,
                    const char *label, const char *value)
{
    if (*n >= max) {
        return;
    }
    strncpy(rows[*n].group, group, sizeof rows[*n].group - 1);
    rows[*n].group[sizeof rows[*n].group - 1] = '\0';
    strncpy(rows[*n].label, label, sizeof rows[*n].label - 1);
    rows[*n].label[sizeof rows[*n].label - 1] = '\0';
    strncpy(rows[*n].value, value, sizeof rows[*n].value - 1);
    rows[*n].value[sizeof rows[*n].value - 1] = '\0';
    ++(*n);
}

int now_gestalt_gather(GestaltRow *rows, int max)
{
    int n = 0;
    long v;
    char sys[20] = "unknown";
    char cpu[24];
    char carbon[16] = "?";
    char model[56];
    char buf[56];
    Boolean has_ot;
    long phys_mb = 0, log_mb = 0;

    machine_model(model, sizeof model);
    if (Gestalt(gestaltSystemVersion, &v) == noErr) {
        char sv[12];
        bcd_version(v, sv, sizeof sv);
        snprintf(sys, sizeof sys, "Mac OS %s", sv);
    }
    if (Gestalt(gestaltNativeCPUtype, &v) == noErr && cpu_name(v) != NULL) {
        snprintf(cpu, sizeof cpu, "%s", cpu_name(v));
    } else if (Gestalt(gestaltProcessorType, &v) == noErr
               && processor_name(v) != NULL) {
        snprintf(cpu, sizeof cpu, "%s", processor_name(v));
    } else {
        strcpy(cpu, "unknown");
    }
    if (Gestalt('cbon', &v) == noErr) {
        bcd_version(v, carbon, sizeof carbon);
    }
    if (Gestalt(gestaltPhysicalRAMSize, &v) == noErr) {
        phys_mb = v / (1024L * 1024L);
    }
    if (Gestalt(gestaltLogicalRAMSize, &v) == noErr) {
        log_mb = v / (1024L * 1024L);
    }
    has_ot = (Gestalt(gestaltOpenTpt, &v) == noErr);

    /* snapshot: the curated, human-readable slice (default view) */
    add_row(rows, &n, max, "snapshot", "Model", model);
    add_row(rows, &n, max, "snapshot", "System", sys);
    add_row(rows, &n, max, "snapshot", "CPU", cpu);
    snprintf(buf, sizeof buf, "%ld MB", phys_mb);
    add_row(rows, &n, max, "snapshot", "Memory", buf);
    add_row(rows, &n, max, "snapshot", "CarbonLib", carbon);
    add_row(rows, &n, max, "snapshot", "Networking",
            has_ot ? "Open Transport" : "MacTCP or none");

    /* cpu */
    add_row(rows, &n, max, "cpu", "Processor", cpu);
    if (Gestalt(gestaltProcessorType, &v) == noErr
        && processor_name(v) != NULL) {
        snprintf(buf, sizeof buf, "%s", processor_name(v));
        add_row(rows, &n, max, "cpu", "68K emulation", buf);
    }
    if (Gestalt(gestaltFPUType, &v) == noErr) {
        add_row(rows, &n, max, "cpu", "FPU", fpu_name(v));
    }
    if (Gestalt(gestaltAddressingModeAttr, &v) == noErr) {
        add_row(rows, &n, max, "cpu", "Addressing", "32-bit");
    }

    /* memory */
    snprintf(buf, sizeof buf, "%ld MB", phys_mb);
    add_row(rows, &n, max, "memory", "Physical RAM", buf);
    if (log_mb > 0) {
        snprintf(buf, sizeof buf, "%ld MB", log_mb);
        add_row(rows, &n, max, "memory", "Logical RAM", buf);
    }
    if (Gestalt(gestaltVMAttr, &v) == noErr) {
        add_row(rows, &n, max, "memory", "Virtual memory",
                (v & (1L << gestaltVMPresent)) ? "on" : "off");
    }
    if (Gestalt(gestaltLogicalPageSize, &v) == noErr) {
        snprintf(buf, sizeof buf, "%ld bytes", v);
        add_row(rows, &n, max, "memory", "Page size", buf);
    }

    /* os */
    add_row(rows, &n, max, "os", "System", sys);
    if (Gestalt(gestaltQuickdrawVersion, &v) == noErr) {
        snprintf(buf, sizeof buf, "%ld.%ld", (v >> 8) & 0xFF, (v >> 4) & 0xF);
        add_row(rows, &n, max, "os", "QuickDraw", buf);
    }
    add_row(rows, &n, max, "os", "AppleEvents",
            (Gestalt(gestaltAppleEventsAttr, &v) == noErr) ? "yes" : "no");
    add_row(rows, &n, max, "os", "Thread Manager",
            (Gestalt('thds', &v) == noErr) ? "yes" : "no");
    add_row(rows, &n, max, "os", "CarbonLib", carbon);

    /* network */
    if (Gestalt(gestaltAppleTalkVersion, &v) == noErr) {
        snprintf(buf, sizeof buf, "%ld", v & 0xFF);
        add_row(rows, &n, max, "network", "AppleTalk", buf);
    }
    add_row(rows, &n, max, "network", "Open Transport",
            has_ot ? "yes" : "no");

    /* hw */
    if (Gestalt(gestaltFPUType, &v) == noErr) {
        add_row(rows, &n, max, "hw", "FPU", fpu_name(v));
    }
    if (Gestalt(gestaltKeyboardType, &v) == noErr) {
        snprintf(buf, sizeof buf, "type %ld", v);
        add_row(rows, &n, max, "hw", "Keyboard", buf);
    }
    if (Gestalt(gestaltMachineType, &v) == noErr) {
        snprintf(buf, sizeof buf, "id %ld", v);
        add_row(rows, &n, max, "hw", "Machine type", buf);
    }
    if (Gestalt(gestaltROMSize, &v) == noErr) {
        snprintf(buf, sizeof buf, "%ld KB", v / 1024L);
        add_row(rows, &n, max, "hw", "ROM size", buf);
    }
    if (Gestalt(gestaltROMVersion, &v) == noErr) {
        snprintf(buf, sizeof buf, "$%04lX", v & 0xFFFF);
        add_row(rows, &n, max, "hw", "ROM version", buf);
    }

    return n;
}

/* --- processes ---------------------------------------------------------- */

int now_process_gather(ProcRow *rows, int max)
{
    /* Spelled-out 4CCs: multi-character char constants warn under -Werror.
       These classify a process's kind, the same test serve_process_list
       makes. */
    const unsigned long kTypeFinder = 0x464E4452UL;   /* 'FNDR' */
    const unsigned long kSigFinder = 0x4D414353UL;    /* 'MACS' */
    ProcessSerialNumber psn = { 0, kNoProcess };
    ProcessSerialNumber front;
    ProcessSerialNumber me;
    Boolean have_front = GetFrontProcess(&front) == noErr;
    /* The same fact the wire's isSelf carries, in the sentence a person
       reads: which of these rows is the application answering you. Both
       guests' ps say "self", because the host console renders both with
       one renderer. */
    Boolean have_self = GetCurrentProcess(&me) == noErr;
    int n = 0;

    while (n < max && GetNextProcess(&psn) == noErr) {
        ProcessInfoRec info;
        Str31 name;
        const char *kind;
        Boolean is_front = false;
        Boolean is_self = false;
        long sz;

        memset(&info, 0, sizeof info);
        info.processInfoLength = sizeof info;
        info.processName = name;
        info.processAppSpec = NULL;
        name[0] = 0;
        if (GetProcessInformation(&psn, &info) != noErr) {
            continue;                 /* unreadable: skip, as the wire does */
        }
        if ((unsigned long)info.processType == kTypeFinder
            || (unsigned long)info.processSignature == kSigFinder) {
            kind = "finder";
        } else if ((info.processMode & modeOnlyBackground) != 0) {
            kind = "background";
        } else {
            kind = "application";
        }
        if (have_front) {
            (void)SameProcess(&psn, &front, &is_front);
        }
        if (have_self) {
            (void)SameProcess(&psn, &me, &is_self);
        }
        memcpy(rows[n].name, name + 1, name[0]);
        rows[n].name[name[0]] = '\0';
        sz = (long)(info.processSize / 1024);
        snprintf(rows[n].detail, sizeof rows[n].detail, "%s, %ld KB%s%s",
                 kind, sz, is_front ? ", front" : "",
                 is_self ? ", self" : "");
        ++n;
    }
    return n;
}

/* --- wire path: serialize the rows to grouped JSON ---------------------- */

/* The group a gestalt console flag selects, or NULL. The guest's own
   console reads the same mapping (console_model.c's flag_to_group); this is
   the wire's copy of one grammar, and the reason the host has none. */
static const char *gestalt_flag_group(const char *flag)
{
    if (strcmp(flag, "--cpu") == 0) { return "cpu"; }
    if (strcmp(flag, "--memory") == 0) { return "memory"; }
    if (strcmp(flag, "--os") == 0) { return "os"; }
    if (strcmp(flag, "--network") == 0) { return "network"; }
    if (strcmp(flag, "--hardware") == 0) { return "hw"; }
    return NULL;
}

static void run_gestalt(const char *request_json, long id, char *out, long cap)
{
    GestaltRow rows[kGestaltMaxRows];
    int count = now_gestalt_gather(rows, kGestaltMaxRows);
    /* every group, in a stable order, snapshot first */
    static const char *const all_groups[] = {
        "snapshot", "cpu", "memory", "os", "network", "hw", NULL
    };
    static const char *const snapshot_only[] = { "snapshot", NULL };
    const char *const *groups = all_groups;
    const char *one[2];
    char line[128];
    char word[32];

    /* No line: a typed caller, which gets every group as it always has.
       A line: a human, who asked for a slice — and the slice is chosen HERE,
       because the console that sent the line cannot read this output's
       shape. */
    if (now_cmd_line(request_json, line, sizeof line)) {
        if (line[0] == '\0') {
            groups = snapshot_only;
        } else if (now_cmd_line_word(line, "--full")) {
            groups = kGestaltFullGroups;
        } else {
            const char *group = NULL;

            /* The group IS a flag, so this reads the line's first word
               rather than going through now_cmd_arg_word, which skips
               flags. */
            now_cmd_first_word(line, word, sizeof word);
            group = gestalt_flag_group(word);
            if (group == NULL) {
                char esc[64];

                now_json_escape(word, esc, sizeof esc);
                snprintf(out, (size_t)cap,
                         "{\"type\":\"command.result\",\"id\":%ld,"
                         "\"ok\":false,\"error\":{\"code\":\"unknown-group\","
                         "\"message\":\"no gestalt group \\\"%s\\\" - see "
                         "help gestalt\"}}", id, esc);
                return;
            }
            one[0] = group;
            one[1] = NULL;
            groups = one;
        }
    }

    /* The serialization itself lives next door, in pure C the host cc can
       compile and gestalt_json_test.c can drive at a cap small enough to
       overflow — which is not a hypothetical shape here: kGestaltMaxRows is
       48 rows of 96 bytes, and the wire's result buffer is 3072. */
    (void)now_gestalt_result_json(id, rows, count, groups, out, cap);
}

static void run_screenshot(const char *request_json, long id,
                           char *out, long cap)
{
    NowPrefs prefs;
    ShotStats stats;
    char err[96];
    char value[16];
    char line[128];
    short depth;
    short bands = 1;
    Boolean save = true;
    long pos;

    now_prefs_load(&prefs);
    depth = prefs.shot_depth;
    /* A console's flags, then the typed args, which win. An unrecognised
       flag is ignored rather than refused: a typo must not cost a capture
       on a machine where one takes a tenth of a second of VRAM reads. */
    if (now_cmd_line(request_json, line, sizeof line)) {
        if (now_cmd_line_flag_value(line, "--depth", value, sizeof value)) {
            long d = strtol(value, NULL, 10);
            if (capture_depth_is_supported((short)d)) {
                depth = (short)d;
            }
        }
        if (now_cmd_line_flag_value(line, "--bands", value, sizeof value)) {
            long b = strtol(value, NULL, 10);
            if (b >= 1 && b <= kCaptureMaxBands) {
                bands = (short)b;
            }
        }
        if (now_cmd_line_word(line, "--no-save")) {
            save = false;
        }
    }
    if (now_json_find_string(request_json, "depth", value, sizeof value)) {
        long d = strtol(value, NULL, 10);
        if (capture_depth_is_supported((short)d)) {
            depth = (short)d;
        }
    }
    if (now_json_find_string(request_json, "bands", value, sizeof value)) {
        long b = strtol(value, NULL, 10);
        if (b >= 1 && b <= kCaptureMaxBands) {
            bands = (short)b;
        }
    }
    if (now_json_find_string(request_json, "save", value, sizeof value)
        && strcmp(value, "false") == 0) {
        save = false;
    }

    if (now_screenshot(depth, bands, save, &stats, err, sizeof err) != 0) {
        snprintf(out, cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                 "\"error\":{\"code\":\"screenshot-failed\","
                 "\"message\":\"%s\"}}", id, err);
        return;
    }
    pos = snprintf(out, cap,
                   "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                   "\"output\":{\"screenshot\":["
                   "[\"Size\",\"%dx%d\"],"
                   "[\"Depth\",\"%d-bit\"],"
                   "[\"Raw\",\"%ld KB\"],"
                   "[\"PICT\",\"%ld KB\"],"
                   "[\"Capture\",\"%ld ms\"],"
                   "[\"Encode\",\"%ld ms\"],",
                   id, stats.width, stats.height, stats.depth,
                   stats.raw_bytes / 1024, stats.pict_bytes / 1024,
                   stats.capture_ms, stats.encode_ms);
    if (stats.bands > 1) {
        pos += snprintf(out + pos, cap - pos,
                        "[\"Bands\",\"%d\"],"
                        "[\"Band min\",\"%ld.%ld ms\"],"
                        "[\"Band max\",\"%ld.%ld ms\"],",
                        stats.bands,
                        stats.band_min_us / 1000,
                        (stats.band_min_us % 1000) / 100,
                        stats.band_max_us / 1000,
                        (stats.band_max_us % 1000) / 100);
    }
    pos += snprintf(out + pos, cap - pos,
                    "[\"Saved\",\"%s\"]]}}",
                    save ? stats.saved_name : "(not saved)");
    (void)pos;
}

static void run_vprobe(long id, char *out, long cap)
{
    VProbeRow rows[20];
    char err[96];
    int n = now_vprobe_run(rows, 20, err, sizeof err);
    long pos;
    int i;

    if (n < 0) {
        snprintf(out, cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                 "\"error\":{\"code\":\"vprobe-failed\","
                 "\"message\":\"%s\"}}", id, err);
        return;
    }
    pos = snprintf(out, cap,
                   "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                   "\"output\":{\"vprobe\":[", id);
    for (i = 0; i < n; ++i) {
        pos += snprintf(out + pos, cap - pos, "[\"%s\",\"%s\"]%s",
                        rows[i].label, rows[i].value,
                        i + 1 < n ? "," : "");
    }
    pos += snprintf(out + pos, cap - pos, "]}}");
    (void)pos;
}

static const char *files_error_text(int rc)
{
    switch (rc) {
    case kFilesBadPath:
        return "bad path (no \"::\", segments <= 31 chars)";
    case kFilesNotFound:
        return "no such folder in the share";
    case kFilesNotAFolder:
        return "that is a file, not a folder";
    case kFilesTooBig:
        return "not enough disk space";
    default:
        return "the File Manager refused";
    }
}

/* ls: one page of the share. The console shows a generous page; the
   Files module pages through file.list instead. */
static void run_ls(const char *request_json, long id, char *out, long cap)
{
    enum { kConsolePage = 48 };
    FileEntry entries[kConsolePage];
    char path[224];
    char root[160];
    char esc_root[340], esc_path[340];
    char value[96];
    Boolean more = false;
    short next = 1;
    int n, i;
    long pos;

    /* The whole line is the path: an HFS name has spaces and quoting them
       would be a second grammar. Decoded, not raw — the File Manager wants
       MacRoman, and "ls Café:Notes" arrives as UTF-8. */
    now_cmd_arg_rest(request_json, "path", path, sizeof path);
    n = now_files_list(path, 1, entries, kConsolePage, &more, &next);
    if (n < 0) {
        snprintf(out, cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                 "\"error\":{\"code\":\"file-error\","
                 "\"message\":\"%s\"}}", id, files_error_text(n));
        return;
    }
    now_files_root_name(root, sizeof root);
    now_json_escape(root, esc_root, sizeof esc_root);
    now_json_escape(path[0] != '\0' ? path : "(root)", esc_path,
                    sizeof esc_path);
    pos = snprintf(out, cap,
                   "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                   "\"output\":{\"ls\":["
                   "[\"Share\",\"%s\"],"
                   "[\"Folder\",\"%s\"]",
                   id, esc_root, esc_path);
    for (i = 0; i < n && pos < cap - 240; ++i) {
        char esc_name[200], esc_value[200];

        now_files_describe(&entries[i], value, sizeof value);
        now_json_escape(entries[i].name, esc_name, sizeof esc_name);
        now_json_escape(value, esc_value, sizeof esc_value);
        pos += snprintf(out + pos, (size_t)(cap - pos),
                        ",[\"%s\",\"%s\"]", esc_name, esc_value);
    }
    if (more || i < n) {
        pos += snprintf(out + pos, (size_t)(cap - pos),
                        ",[\"...\",\"more entries follow\"]");
    }
    snprintf(out + pos, (size_t)(cap - pos), "]}}");
}

/* putstat: where the last received file's time actually went. Measured
   where the work happens, since inferring it from the far end of a wire
   confuses "slow to arrive" with "slow to write". */
static void run_putstat(long id, char *out, long cap)
{
    FileReceiveStats st;

    now_files_receive_stats(&st);
    snprintf(out, cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"putstat\":["
             "[\"Bytes\",\"%ld\"],"
             "[\"Chunks\",\"%ld\"],"
             "[\"Writes\",\"%ld\"],"
             "[\"In FSWrite\",\"%lu ms\"],"
             "[\"In receive\",\"%lu ms\"],"
             /* Resume has no other visible trace: without these two a
                resumed transfer and a fresh one look identical from
                here, and the only way to tell them apart is a
                debugger on a machine that may not have one. */
             "[\"Resumed from\",\"%ld\"],"
             "[\"CRC reseed\",\"%lu ms\"],"
             "[\"CRC-32\",\"%08lx\"],"
             "[\"Rcv backlog\",\"%ld\"],"
             "[\"Rcv peak\",\"%ld\"],"
             "[\"Loop passes\",\"%ld\"]"
             "]}}",
             id, st.bytes, st.chunks, st.writes,
             st.us_write / 1000, st.us_total / 1000,
             st.resumed_from, st.us_reseed / 1000, st.crc,
             conn_rcv_window(),
             conn_rcv_peak(), conn_service_passes());
}

/* wirestat: how long this guest takes to NOTICE, as a distribution.

   The three numbers a host can see - bytes, walk time, round trip -
   cannot separate "the answer was expensive" from "nobody looked at the
   socket for a tenth of a second", and on 2026-08-06 a round trip cost
   115 ms whose answer was zero bytes. So the guest reports what only it
   can: the interval between its own service passes, and the delay from
   Open Transport announcing data to this loop reading it.

   HISTOGRAMS, not medians. A cooperatively scheduled Macintosh produces
   a tail that a single number hides, and the tail is what a person
   feels. The bucket edges are published in the rows themselves so a
   reader is never guessing what a column counts.

   It also SETS the two things under test - the idle sleep and the wake -
   because a comparison made across two boots is a comparison of two
   machines. Both are runtime state and neither is saved: a diagnostic
   that survives a relaunch is a configuration nobody chose. */
static void wirestat_hist(const LoopStat *s, const char *what,
                          char *out, long cap, long *pos)
{
    int i;
    int med = loopstat_median_bucket(s);
    long lo = 0;

    *pos += snprintf(out + *pos, (size_t)(cap - *pos),
                     ",[\"%s n\",\"%ld\"]"
                     ",[\"%s mean\",\"%lu us\"]"
                     ",[\"%s min\",\"%lu us\"]"
                     ",[\"%s max\",\"%lu us\"]",
                     what, s->n, what, loopstat_mean_us(s),
                     what, s->n > 0 ? s->min_us : 0UL, what, s->max_us);
    for (i = 0; i < kLoopStatBuckets; ++i) {
        unsigned long hi = loopstat_edge_us(i);

        if (s->buckets[i] == 0 && i != med) {
            lo = (long)hi;
            continue;                 /* empty bins are noise, not data */
        }
        if (hi != 0) {
            *pos += snprintf(out + *pos, (size_t)(cap - *pos),
                             ",[\"%s %ld-%lu us%s\",\"%ld\"]",
                             what, lo, hi, i == med ? " (median)" : "",
                             s->buckets[i]);
        } else {
            *pos += snprintf(out + *pos, (size_t)(cap - *pos),
                             ",[\"%s %ld+ us%s\",\"%ld\"]",
                             what, lo, i == med ? " (median)" : "",
                             s->buckets[i]);
        }
        lo = (long)hi;
    }
}

static void run_wirestat(const char *request_json, long id,
                         char *out, long cap)
{
    ConnWakeStats st;
    char line[64];
    char action[24];
    char value[24];
    WireStatRequest req;
    long pos;

    /* TWO FACES, ONE GRAMMAR. A console sends the raw line and a typed
       caller sends args; now_cmd_arg_word answers the named arg for the
       second but the line's FIRST word for the first, so asking it twice
       on a console line returns "sleep" for both `action` and `value`
       and `wirestat sleep 3` becomes `sleep 0`. The split and the
       meaning are in wirestat_cmd.c, with a native test. */
    if (now_cmd_line(request_json, line, sizeof line)) {
        now_wirestat_split(line, action, sizeof action, value, sizeof value);
    } else {
        action[0] = value[0] = '\0';
        now_cmd_arg_word(request_json, "action", action, sizeof action);
        now_cmd_arg_word(request_json, "value", value, sizeof value);
    }
    now_wirestat_parse(action, value, &req);
    if (req.set_wake) {
        conn_set_wake(req.wake_on);
    }
    if (req.set_sleep) {
        conn_set_idle_sleep(req.sleep_ticks);
    }
    if (req.reset || req.set_wake || req.set_sleep) {
        conn_reset_wake_stats();
    }

    conn_wake_stats(&st);
    pos = snprintf(out, (size_t)cap,
                   "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                   "\"output\":{\"wirestat\":["
                   "[\"Sleep now\",\"%ld tick(s)\"],"
                   "[\"Idle sleep\",\"%ld tick(s)\"],"
                   "[\"Wake on data\",\"%s\"],"
                   /* Whether the notifier is LIVE, separately from
                      whether the wake is on. They are different failures:
                      a notifier that never installed reports no arrivals
                      at all, which reads exactly like a quiet wire. */
                   "[\"Notifier\",\"%s\"],"
                   "[\"Data notifications\",\"%ld\"],"
                   "[\"WakeUpProcess calls\",\"%ld\"]",
                   id, st.sleep_ticks, conn_idle_sleep(),
                   st.wake_enabled ? "on" : "off",
                   st.notifier_live ? "installed" : "absent",
                   st.data_events, st.wake_calls);
    wirestat_hist(&st.pass, "pass", out, cap, &pos);
    wirestat_hist(&st.wake, "notice", out, cap, &pos);
    snprintf(out + pos, (size_t)(cap - pos), "]}}");
}

/* net: what this Mac can say about its own networking, as rows.
   Reuses the [label, value] shape every other command returns, which is
   why it needs no new wire type and no host decoder - the conformance
   gate would redden on a type the host cannot read, and there is no
   reason to mint one for a table.

   The rows come from the same net_probe/net_layout pair the guest's own
   Networking page draws, so the two surfaces cannot disagree about what
   this Mac's networking looks like. In particular the Connections row
   says what it says HERE too: a caller that asked over the wire deserves
   the same honest answer as a person at the keyboard, rather than an
   empty list they would read as "none". */
/* Mirror's residents, its agent and the port beside it. The whole verb is
   a probe and an emitter, because the page this shares its facts with was
   already built that way (src/mirror/) - and because a host CANNOT answer
   this question: residency is a Gestalt answer, and a folder listing over
   the file plane cannot tell an installed extension from a loaded one.

   `note` is left alone deliberately. It is the last button-press's
   outcome and belongs to the page a person is looking at; a caller over
   the wire pressed nothing, so there is nothing for it to say. */
static void run_mirror(long id, char *out, long cap)
{
    MirrorFacts facts;

    memset(&facts, 0, sizeof facts);
    now_mirror_probe(&facts);
    now_mirror_json(&facts, id, out, cap);
}

static void run_net(long id, char *out, long cap)
{
    NetFacts facts;
    NetLinkSample link;
    long n;
    int sec;
    Boolean first = true;

    memset(&link, 0, sizeof link);
    link.rtt_ms = -1;
    link.quiet_secs = -1;
    if (conn_is_connected()) {
        ConnSnapshot snap;

        conn_snapshot(&snap);
        link.connected = true;
        conn_peer_label(link.peer, (long)sizeof link.peer);
        link.port = (unsigned long)snap.port;
        link.up_secs = snap.connected_secs > 0
            ? (unsigned long)snap.connected_secs : 0UL;
        link.quiet_secs = snap.quiet_secs;
        link.rtt_ms = conn_last_rtt_ms();
        link.rcv_window = conn_rcv_window();
        link.rcv_peak = conn_rcv_peak();
    }
    now_net_probe(&link, &facts);

    n = snprintf(out, cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                 "\"output\":{\"net\":[", id);

    for (sec = 0; sec < (int)kNetSectionCount && n < cap; ++sec) {
        short rows = now_net_section_rows((NetSection)sec, &facts);
        short i;

        /* A section header row, so the far end sees the same four
           groups a person does rather than one flat list. */
        n += snprintf(out + n, cap - n, "%s[\"%s\",\"\"]",
                      first ? "" : ",", now_net_section_title((NetSection)sec));
        first = false;

        if (rows == 0) {
            NetFactState st = kNetFactNotServed;

            switch ((NetSection)sec) {
            case kNetSectionLink:        st = facts.link.state; break;
            case kNetSectionInet:        st = facts.inet.state; break;
            case kNetSectionPorts:       st = facts.ports_state; break;
            case kNetSectionConnections: st = facts.connections; break;
            case kNetSectionCount:       break;
            }
            /* The token rather than the sentence: a caller matching on
               "undocumented" should not have to parse prose, and the
               prose is the page's job. */
            n += snprintf(out + n, cap - n, ",[\"  (%s)\",\"%s\"]",
                          now_net_state_token(st),
                          now_net_state_sentence(st));
            continue;
        }
        for (i = 0; i < rows && n < cap; ++i) {
            char label[48];
            char value[80];

            if (!now_net_row((NetSection)sec, &facts, i, label, sizeof label,
                             value, sizeof value)) {
                break;
            }
            n += snprintf(out + n, cap - n, ",[\"  %s\",\"%s\"]",
                          label, value);
        }
    }
    if (n < cap) {
        snprintf(out + n, cap - n, "]}}");
    }
}

/* The last lines of this launch's log, one ROW per line so either
   console renders them aligned rather than as one long string. A row is
   [time, the rest] — the shape every other command returns, which is
   why a new command needs no host code.

   Bounded by BYTES, not just line count: a control frame caps at 4 KB
   and forty long lines do not fit. When they do not, the OLDEST go and
   the answer says so; a tail that silently shortens is a tail that lies
   about what happened most recently. */
static void run_tail(const char *request_json, long id, char *out, long cap)
{
    char lines[2600];
    /* tail never returns more than 40 lines (the cap below); size the
       index to that, not to the whole ring, which is now thousands. */
    const char *starts[kLogTailMax];
    char line[128];
    long want = now_json_find_int(request_json, "lines", 20);
    long pos;
    long budget;
    int got, first, i;
    char *p;

    /* "tail 40": the count is the first integer on the line. The typed
       arg wins, so a module asking for 20 still gets 20. */
    if (now_json_value(request_json, "lines") == NULL
        && now_cmd_line(request_json, line, sizeof line)) {
        long typed;

        if (now_cmd_line_int(line, &typed)) {
            want = typed;
        }
    }
    if (want < 1) {
        want = 1;
    }
    if (want > 40) {
        want = 40;
    }
    got = now_log_tail((int)want, lines, sizeof lines);

    /* now_log_tail writes oldest first; index them in place. */
    p = lines;
    for (i = 0; i < got && p != NULL && *p != '\0'; ++i) {
        starts[i] = p;
        p = strchr(p, '\n');
        if (p != NULL) {
            *p++ = '\0';
        }
    }
    got = i;

    /* Walk backwards from the newest to find how many fit, so that the
       lines dropped are the ones furthest from what just happened. */
    budget = cap - 160;               /* the JSON around the rows */
    first = got;
    for (i = got - 1; i >= 0; --i) {
        long len = (long)strlen(starts[i]) * 6 + 8;   /* worst-case escape */

        if (budget - len < 0) {
            break;
        }
        budget -= len;
        first = i;
    }

    pos = snprintf(out, (size_t)cap,
                   "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                   "\"output\":{\"tail\":[", id);
    for (i = first; i < got; ++i) {
        char stamp[16];
        char esc_time[40];
        char esc_rest[320];
        const char *rest = starts[i];
        const char *space = strchr(starts[i], ' ');

        if (space != NULL && space - starts[i] < (long)sizeof stamp) {
            memcpy(stamp, starts[i], (size_t)(space - starts[i]));
            stamp[space - starts[i]] = '\0';
            rest = space + 1;
        } else {
            stamp[0] = '\0';
        }
        now_json_escape(stamp, esc_time, sizeof esc_time);
        now_json_escape(rest, esc_rest, sizeof esc_rest);
        pos += snprintf(out + pos, (size_t)cap - (size_t)pos,
                        "%s[\"%s\",\"%s\"]", i > first ? "," : "",
                        esc_time, esc_rest);
    }
    snprintf(out + pos, (size_t)cap - (size_t)pos,
             "],\"log\":[[\"file\",\"%s\"],[\"shown\",\"%d of %d%s\"]]}}",
             now_log_path(), got - first, got,
             first > 0 ? " (older ones did not fit)" : "");
}

/* ps: the running processes as flat [name, detail] rows. The Processes
   module drives process.list (PSNs, paging); this is the reading of it. */
static void run_ps(long id, char *out, long cap)
{
    ProcRow rows[kProcMaxRows];
    int n = now_process_gather(rows, kProcMaxRows);
    long pos;
    int i;

    pos = snprintf(out, (size_t)cap,
                   "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                   "\"output\":{\"ps\":[", id);
    for (i = 0; i < n && pos < cap - 200; ++i) {
        char esc_name[64], esc_detail[128];

        now_json_escape(rows[i].name, esc_name, sizeof esc_name);
        now_json_escape(rows[i].detail, esc_detail, sizeof esc_detail);
        pos += snprintf(out + pos, (size_t)(cap - pos), "%s[\"%s\",\"%s\"]",
                        i > 0 ? "," : "", esc_name, esc_detail);
    }
    snprintf(out + pos, (size_t)(cap - pos), "]}}");
}

/* census: one probe, one page, as flat [name, meaning] rows. The raw value
   folds into the meaning column when a row has no decoded form, so nothing
   the wire triple carries is dropped. No probe name runs "overview"; an
   unknown one is a well-formed ok=false, never a protocol error. */
static void run_census(const char *request_json, long id, char *out, long cap)
{
    char probe[24];
    CensusPage page;
    long pos;
    int i;

    now_cmd_arg_word(request_json, "probe", probe, sizeof probe);
    if (probe[0] == '\0') {
        strcpy(probe, "overview");
    }
    if (now_census_gather(probe, 0, &page) != 0) {
        char esc[40];
        now_json_escape(probe, esc, sizeof esc);
        snprintf(out, (size_t)cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                 "\"error\":{\"code\":\"unknown-probe\","
                 "\"message\":\"no census probe \\\"%s\\\" - see help census\""
                 "}}", id, esc);
        return;
    }
    pos = snprintf(out, (size_t)cap,
                   "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                   "\"output\":{\"census\":[", id);
    for (i = 0; i < page.count && pos < cap - 240; ++i) {
        const char *value = page.rows[i].meaning[0] != '\0'
            ? page.rows[i].meaning : page.rows[i].raw;
        char esc_name[64], esc_value[160];

        now_json_escape(page.rows[i].name, esc_name, sizeof esc_name);
        now_json_escape(value, esc_value, sizeof esc_value);
        pos += snprintf(out + pos, (size_t)(cap - pos), "%s[\"%s\",\"%s\"]",
                        i > 0 ? "," : "", esc_name, esc_value);
    }
    /* An empty page (absent), a partial one, or a note has nothing in the
       rows to say so — carry the outcome in a trailing row rather than
       leaving the console blank. */
    if (page.count == 0 || page.outcome != kCensusPresent
        || page.note[0] != '\0' || page.more) {
        char status[kCensusNoteCap + 32];
        char esc_status[240];

        if (page.note[0] != '\0') {
            snprintf(status, sizeof status, "%s - %s",
                     census_outcome_name(page.outcome), page.note);
        } else {
            snprintf(status, sizeof status, "%s%s",
                     census_outcome_name(page.outcome),
                     page.more ? " (more follows)" : "");
        }
        now_json_escape(status, esc_status, sizeof esc_status);
        pos += snprintf(out + pos, (size_t)(cap - pos),
                        "%s[\"(%s)\",\"%s\"]", page.count > 0 ? "," : "",
                        probe, esc_status);
    }
    snprintf(out + pos, (size_t)(cap - pos), "]}}");
}

/* catsearch: what a whole-volume application sweep costs, measured where
   the disk is. Rows go through the escaper because two of them carry
   catalog strings — the volume's name and the first hits' names — and a
   quote in a file name must stay a file name, not become JSON. */

static const char *catsearch_row_value(const CatSearchRow *rows, int n,
                                       const char *label)
{
    int i;

    for (i = 0; i < n; ++i) {
        if (strcmp(rows[i].label, label) == 0) {
            return rows[i].value;
        }
    }
    return "?";
}

static void run_catsearch(long id, char *out, long cap)
{
    CatSearchRow rows[16];
    char cerr[96];
    long pos;
    int n;
    int i;

    /* Begun-then-ended, because the sweep stalls the wire for seconds:
       a log that ends on "begun" names the crash site. */
    now_log(kLogInfo, "sw", "#%ld catsearch begun", id);
    n = now_catsearch_run(rows, 16, cerr, sizeof cerr);
    if (n < 0) {
        char esc[200];

        now_log(kLogWarn, "sw", "#%ld catsearch failed: %.60s", id, cerr);
        now_json_escape(cerr, esc, sizeof esc);
        snprintf(out, cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                 "\"error\":{\"code\":\"catsearch-failed\","
                 "\"message\":\"%s\"}}", id, esc);
        return;
    }
    now_log(kLogInfo, "sw", "#%ld catsearch: %.15s hits, cold %.40s", id,
            catsearch_row_value(rows, n, "APPL hits"),
            catsearch_row_value(rows, n, "Cold sweep"));
    pos = snprintf(out, (size_t)cap,
                   "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                   "\"output\":{\"catsearch\":[", id);
    for (i = 0; i < n && pos < cap - 240; ++i) {
        char esc_label[64], esc_value[200];

        now_json_escape(rows[i].label, esc_label, sizeof esc_label);
        now_json_escape(rows[i].value, esc_value, sizeof esc_value);
        pos += snprintf(out + pos, (size_t)(cap - pos), "%s[\"%s\",\"%s\"]",
                        i > 0 ? "," : "", esc_label, esc_value);
    }
    snprintf(out + pos, (size_t)(cap - pos), "]}}");
}

/* sw: the installed-software inventory. No domain = the overview of
   counts; a domain = one page of its items. Rows are catalog strings,
   so everything goes through the escaper. */
static void run_sw(const char *request_json, long id, char *out, long cap)
{
    SoftwareRow rows[kSoftwareRowMax];
    char domain[16];
    Boolean more = false;
    long pos;
    int n, i;

    now_cmd_arg_word(request_json, "domain", domain, sizeof domain);
    if (domain[0] == '\0') {
        n = now_software_overview(rows, kSoftwareRowMax);
    } else {
        n = now_software_gather(domain, rows, kSoftwareRowMax, &more);
    }
    if (n < 0) {
        char esc[40];

        now_json_escape(domain, esc, sizeof esc);
        snprintf(out, (size_t)cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                 "\"error\":{\"code\":\"unknown-domain\","
                 "\"message\":\"no software domain \\\"%s\\\" - "
                 "see help sw\"}}", id, esc);
        return;
    }
    pos = snprintf(out, (size_t)cap,
                   "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                   "\"output\":{\"sw\":[", id);
    for (i = 0; i < n && pos < cap - 240; ++i) {
        char esc_name[80], esc_detail[120];

        now_json_escape(rows[i].name, esc_name, sizeof esc_name);
        now_json_escape(rows[i].detail, esc_detail, sizeof esc_detail);
        pos += snprintf(out + pos, (size_t)(cap - pos), "%s[\"%s\",\"%s\"]",
                        i > 0 ? "," : "", esc_name, esc_detail);
    }
    if (more || i < n) {
        pos += snprintf(out + pos, (size_t)(cap - pos),
                        ",[\"...\",\"more items follow\"]");
    }
    snprintf(out + pos, (size_t)(cap - pos), "]}}");
}

/* launch: the family's one mutation, so it logs both outcomes — and the
   refusal reason goes to the log, not only back down the wire. */
static void run_launch(const char *request_json, long id, char *out,
                       long cap)
{
    char arg[256];
    char msg[240];
    char esc[480];

    /* "target", never "name" — see run_vers. The whole console line is the
       target, flags and all: the grammar is proc_quit_args.c's and
       now_software_launch's, parsed here, once. */
    now_cmd_arg_rest(request_json, "target", arg, sizeof arg);
    if (now_software_launch(arg, msg, sizeof msg) < 0) {
        now_log(kLogWarn, "sw", "#%ld launch refused: %.80s", id, msg);
        now_json_escape(msg, esc, sizeof esc);
        snprintf(out, (size_t)cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                 "\"error\":{\"code\":\"launch-refused\","
                 "\"message\":\"%s\"}}", id, esc);
        return;
    }
    now_log(kLogInfo, "sw", "#%ld %.80s", id, msg);
    now_json_escape(msg, esc, sizeof esc);
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"launch\":[[\"Launch\",\"%s\"]]}}", id, esc);
}

/* quit: launch's opposite number, and the harder half. launch either
   opened something or did not; quit has to distinguish "gone" from
   "asked, and it said no" — so the outcome travels as its own machine-
   readable row beside the sentence, and only the two states that mean
   "the process is not running" answer ok:true.
   ok:false for a DECLINED quit is deliberate. The command did exactly
   what the platform allows and the reply is still a failure, because the
   caller's purpose — usually "the port is free now, go probe" — was not
   served. A measurement loop that reads ok:true and proceeds is the
   defect this row exists to prevent. */
static void run_quit(const char *request_json, long id, char *out, long cap)
{
    char arg[256];
    char msg[240];
    char esc[480];
    NowProcQuitOutcome outcome;
    const char *state;
    const char *code = NULL;

    /* "target", never "name" — see run_vers. The whole console line is the
       target, flags and all: the grammar is proc_quit_args.c's and
       now_software_launch's, parsed here, once. */
    now_cmd_arg_rest(request_json, "target", arg, sizeof arg);
    outcome = now_proc_quit_by_name(arg, msg, sizeof msg);
    switch (outcome) {
    case kProcQuitGone:         state = "gone"; break;
    case kProcQuitNotRunning:   state = "not-running"; break;
    case kProcQuitSent:         state = "sent-unconfirmed"; break;
    case kProcQuitStillRunning: state = "still-running";
                                code = "quit-declined"; break;
    case kProcQuitAmbiguous:    state = "ambiguous";
                                code = "quit-ambiguous"; break;
    case kProcQuitRefusedSelf:  state = "refused-self";
                                code = "quit-refused"; break;
    case kProcQuitSendFailed:   state = "undeliverable";
                                code = "quit-undeliverable"; break;
    case kProcQuitBadArgs:
    default:                    state = "bad-args";
                                code = "quit-bad-args"; break;
    }

    now_json_escape(msg, esc, sizeof esc);
    /* Mutations log both outcomes; a declined quit that is only ever seen
       in a window nobody kept is the one worth having on the platter. */
    now_log(code == NULL ? kLogInfo : kLogWarn, "proc",
            "#%ld quit [%s] %.80s", id, state, msg);
    if (code != NULL) {
        snprintf(out, (size_t)cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                 "\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}",
                 id, code, esc);
        return;
    }
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"quit\":[[\"Quit\",\"%s\"],"
             "[\"Outcome\",\"%s\"]]}}", id, esc, state);
}

/* front: quit's gentler sibling, over the same composition. The one
   difference worth reading twice is that not-running is ok:FALSE here.
   quit's is ok:true because "not running" is the state it was asked to
   produce; front cannot produce anything from a process that is not
   there, and a caller whose next step assumes a window is up would be
   poisoned by a true. See proc_actions.h. */
static void run_front(const char *request_json, long id, char *out, long cap)
{
    char arg[256];
    char msg[240];
    char esc[480];
    NowProcFrontOutcome outcome;
    const char *state;
    const char *code = NULL;

    /* "target", never "name" — see run_vers. The whole line is the name;
       front has no flags, so nothing has to lead. */
    now_cmd_arg_rest(request_json, "target", arg, sizeof arg);
    outcome = now_proc_front_by_name(arg, msg, sizeof msg);
    switch (outcome) {
    case kProcFrontDone:        state = "fronted"; break;
    case kProcFrontUnconfirmed: state = "unconfirmed";
                                code = "front-unconfirmed"; break;
    case kProcFrontNotRunning:  state = "not-running";
                                code = "front-not-running"; break;
    case kProcFrontAmbiguous:   state = "ambiguous";
                                code = "front-ambiguous"; break;
    case kProcFrontRefused:     state = "refused";
                                code = "front-refused"; break;
    case kProcFrontBadArgs:
    default:                    state = "bad-args";
                                code = "front-bad-args"; break;
    }

    now_json_escape(msg, esc, sizeof esc);
    now_log(code == NULL ? kLogInfo : kLogWarn, "proc",
            "#%ld front [%s] %.80s", id, state, msg);
    if (code != NULL) {
        snprintf(out, (size_t)cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                 "\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}",
                 id, code, esc);
        return;
    }
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"front\":[[\"Front\",\"%s\"],"
             "[\"Outcome\",\"%s\"]]}}", id, esc, state);
}

/* hide: the Application menu's own effect, reached through the Process
   Manager call that menu ends up in. Three rows rather than front's two,
   and the third is the point — a caller reads what IsProcessVisible said
   instead of parsing the sentence, and an outcome that observed nothing
   answers "unknown" rather than the state it asked for. The ok/state/code
   decision is proc_hide_args.c's, in one place, so this renderer cannot
   invent a reply that carries an error code and ok:true. */
static void run_hide(const char *request_json, long id, char *out, long cap)
{
    char arg[256];
    char msg[240];
    char esc[480];
    NowProcHideOutcome outcome;
    const char *code;

    /* "target", never "name" — see run_vers. The whole line is the name,
       flags leading, because process names have spaces. */
    now_cmd_arg_rest(request_json, "target", arg, sizeof arg);
    outcome = now_proc_hide_by_name(arg, msg, sizeof msg);
    code = now_proc_hide_error(outcome);

    now_json_escape(msg, esc, sizeof esc);
    now_log(code == NULL ? kLogInfo : kLogWarn, "proc",
            "#%ld hide [%s] %.80s", id, now_proc_hide_state(outcome), msg);
    if (code != NULL) {
        snprintf(out, (size_t)cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                 "\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}",
                 id, code, esc);
        return;
    }
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"hide\":[[\"Hide\",\"%s\"],"
             "[\"Outcome\",\"%s\"],[\"Visible\",\"%s\"]]}}",
             id, esc, now_proc_hide_state(outcome),
             now_proc_hide_visible_word(outcome));
}

/* reveal: launch's read-only twin — it shows a selection in this Mac's
   Finder and mutates nothing, so it logs at info either way. */
static void run_reveal(const char *request_json, long id, char *out,
                       long cap)
{
    char arg[256];
    char msg[240];
    char esc[480];

    /* "target", never "name" — see run_vers. The whole console line is the
       target, flags and all: the grammar is proc_quit_args.c's and
       now_software_launch's, parsed here, once. */
    now_cmd_arg_rest(request_json, "target", arg, sizeof arg);
    if (now_software_reveal_target(arg, msg, sizeof msg) < 0) {
        now_log(kLogInfo, "sw", "#%ld reveal declined: %.80s", id, msg);
        now_json_escape(msg, esc, sizeof esc);
        snprintf(out, (size_t)cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                 "\"error\":{\"code\":\"reveal-refused\","
                 "\"message\":\"%s\"}}", id, esc);
        return;
    }
    now_log(kLogInfo, "sw", "#%ld %.80s", id, msg);
    now_json_escape(msg, esc, sizeof esc);
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"reveal\":[[\"Reveal\",\"%s\"]]}}", id, esc);
}

/* vers: one file's version resources, read alone — the lazy detail the
   Software page will hang on a selected row. */
static void run_vers(const char *request_json, long id, char *out,
                     long cap)
{
    SoftwareRow rows[40];
    char arg[256];
    char msg[240];
    long pos;
    int n, i;

    /* "target", never "name": the frame is scanned FLAT, and an arg key
       that shadows an envelope key (type/id/name/args/line) is read as the
       command name — launch shipped that bug to metal. The rule lives in
       the contract's x-commands preamble.

       find_TEXT, never find_string, for both the typed arg and the console
       line: the host sends an HFS name as UTF-8 (® is 0xC2 0xAE), and
       FSMakeFSSpec wants the MacRoman byte (0xA8). find_text is the inbound
       half of now_json_escape — it decodes \u and raw UTF-8 back to
       MacRoman. Without it a non-ASCII name round-trips to "no such file"
       and the echoed path double-mangles (® -> ¬Æ). */
    now_cmd_arg_rest(request_json, "target", arg, sizeof arg);
    n = now_software_vers(arg, rows, 40, msg, sizeof msg);
    if (n < 0) {
        char esc[480];

        now_json_escape(msg, esc, sizeof esc);
        snprintf(out, (size_t)cap,
                 "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                 "\"error\":{\"code\":\"vers-refused\","
                 "\"message\":\"%s\"}}", id, esc);
        return;
    }
    pos = snprintf(out, (size_t)cap,
                   "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                   "\"output\":{\"vers\":[", id);
    for (i = 0; i < n && pos < cap - 240; ++i) {
        char esc_name[80], esc_detail[160];

        now_json_escape(rows[i].name, esc_name, sizeof esc_name);
        now_json_escape(rows[i].detail, esc_detail, sizeof esc_detail);
        pos += snprintf(out + pos, (size_t)(cap - pos), "%s[\"%s\",\"%s\"]",
                        i > 0 ? "," : "", esc_name, esc_detail);
    }
    snprintf(out + pos, (size_t)(cap - pos), "]}}");
}

/* help: what THIS machine serves, asked of the machine that serves it.
   The rows come from cmd_help.c, the one table this Mac's own console reads
   too — so the answer cannot drift from the help a human sees here.

   Only the WIRE rows: the console-local verbs (put, mv, trash, ...) are not
   command.requests, and offering one to the other side would send something
   this dispatch answers "unknown-command".

   Bounded by BYTES against the control-frame cap, oldest-first: a list that
   silently loses its tail is a list that lies about what is installed, so
   the truncation says so in a row of its own. */
static void run_help(const char *request_json, long id, char *out, long cap)
{
    char topic[32];
    const NowCommandDoc *doc;
    long pos;
    int i;

    now_cmd_arg_word(request_json, "topic", topic, sizeof topic);

    if (topic[0] != '\0') {
        char esc[240];

        doc = now_command_doc(topic);
        if (doc == NULL || !doc->wire) {
            now_json_escape(topic, esc, sizeof esc);
            snprintf(out, (size_t)cap,
                     "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
                     "\"error\":{\"code\":\"unknown-command\","
                     "\"message\":\"%s is not a command this Mac knows\"}}",
                     id, esc);
            return;
        }
        pos = snprintf(out, (size_t)cap,
                       "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                       "\"output\":{\"help\":[", id);
        now_json_escape(doc->summary, esc, sizeof esc);
        pos += snprintf(out + pos, (size_t)(cap - pos), "[\"%s\",\"%s\"]",
                        doc->name, esc);
        now_json_escape(doc->usage, esc, sizeof esc);
        pos += snprintf(out + pos, (size_t)(cap - pos),
                        ",[\"Usage\",\"%s\"]", esc);
        for (i = 0; doc->detail != NULL && doc->detail[i] != NULL; ++i) {
            if (pos > cap - 320) {
                break;
            }
            now_json_escape(doc->detail[i], esc, sizeof esc);
            pos += snprintf(out + pos, (size_t)(cap - pos),
                            ",[\"\",\"%s\"]", esc);
        }
        snprintf(out + pos, (size_t)(cap - pos), "]}}");
        return;
    }

    pos = snprintf(out, (size_t)cap,
                   "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                   "\"output\":{\"help\":[", id);
    for (i = 0; kNowCommandDocs[i].name != NULL; ++i) {
        char esc[160];

        if (!kNowCommandDocs[i].wire) {
            continue;
        }
        if (pos > cap - 320) {
            pos += snprintf(out + pos, (size_t)(cap - pos),
                            "%s[\"...\",\"more commands than fit one frame\"]",
                            out[pos - 1] != '[' ? "," : "");
            break;
        }
        now_json_escape(kNowCommandDocs[i].summary, esc, sizeof esc);
        pos += snprintf(out + pos, (size_t)(cap - pos), "%s[\"%s\",\"%s\"]",
                        pos > 0 && out[pos - 1] != '[' ? "," : "",
                        kNowCommandDocs[i].name, esc);
    }
    snprintf(out + pos, (size_t)(cap - pos), "]}}");
}

void now_command_run(const char *name, const char *request_json, long id,
                     char *out, long cap)
{
    if (strcmp(name, "help") == 0) {
        run_help(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "gestalt") == 0) {
        run_gestalt(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "screenshot") == 0) {
        run_screenshot(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "vprobe") == 0) {
        run_vprobe(id, out, cap);
        return;
    }
    if (strcmp(name, "net") == 0) {
        run_net(id, out, cap);
        return;
    }
    if (strcmp(name, "mirror") == 0) {
        run_mirror(id, out, cap);
        return;
    }
    if (strcmp(name, "wirestat") == 0) {
        run_wirestat(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "putstat") == 0) {
        run_putstat(id, out, cap);
        return;
    }
    /* What the desktop is drawn from, from the Appearance Manager rather
       than from a resource nobody updates - see desktop.h. Takes no
       arguments, so the console reaches it through console_model.c's
       fallback and renders it with the same row renderer. */
    if (strcmp(name, "desktop") == 0) {
        now_desktop_command(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "ls") == 0) {
        run_ls(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "tail") == 0) {
        run_tail(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "ps") == 0) {
        run_ps(id, out, cap);
        return;
    }
    if (strcmp(name, "census") == 0) {
        run_census(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "catsearch") == 0) {
        run_catsearch(id, out, cap);
        return;
    }
    if (strcmp(name, "sw") == 0) {
        run_sw(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "launch") == 0) {
        run_launch(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "quit") == 0) {
        run_quit(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "front") == 0) {
        run_front(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "hide") == 0) {
        run_hide(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "reveal") == 0) {
        run_reveal(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "vers") == 0) {
        run_vers(request_json, id, out, cap);
        return;
    }
    /* The act plane (P4). Seven commands, one mechanism: an element this
       Mac observed, revalidated here before anything is dispatched, and
       a reply that claims the event went and never that it worked. The
       handlers live in src/act/ rather than here because the plane is
       its own domain with its own Toolbox-free half - see act_cmds.h. */
    /* elements is the reference layer's walk aimed by a process rather
       than by a scope. It lives with observe and not with the act verbs
       because minting is one mechanism with one implementation: two
       verbs that both produced references would be two systems making
       one token shape, and a caller holding one could not tell which. */
    if (strcmp(name, "elements") == 0) {
        now_observe_elements_command(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "winact") == 0) {
        now_act_run_winact(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "textget") == 0) {
        now_act_run_textget(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "textset") == 0) {
        now_act_run_textset(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "ctlact") == 0) {
        now_act_run_ctlact(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "ditemact") == 0) {
        now_act_run_ditemact(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "menuact") == 0) {
        now_act_run_menuact(request_json, id, out, cap);
        return;
    }
    /* Two verbs about the MACHINE rather than about an element, folded in
       from timbottu/mirror (docs/mirror-wave3-verdicts.md). They sit with
       the act plane because that is what they are about: `activate` is
       the switch a driver performs between two acts, and `actselftest` is
       the only instrument that reads the act plane's trap ABI from the
       CALLER's side - see mach_verbs.h. */
    if (strcmp(name, "activate") == 0) {
        now_mach_run_activate(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "actselftest") == 0) {
        now_mach_run_actselftest(request_json, id, out, cap);
        return;
    }
    /* The input plane. `mouseloc` is a READ and is the instrument every
       hop calibration in the probes closes its loop against; `key` is the
       one verb here that drives the machine without addressing an
       element, and it is honest about the one thing it cannot do;
       `script` and `aesend` are the two ways to ask an application to do
       something without an element reference at all. See input_cmds.h. */
    if (strcmp(name, "mouseloc") == 0) {
        now_input_run_mouseloc(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "key") == 0) {
        now_input_run_key(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "script") == 0) {
        now_input_run_script(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "aesend") == 0) {
        now_input_run_aesend(request_json, id, out, cap);
        return;
    }
    /* The content plane's reader (P3). Four subcommands behind one verb,
       selected by `op` - see qdtrace.h on why a drain is a bounded
       control answer and not a transfer. */
    if (strcmp(name, "qdtrace") == 0) {
        now_qdtrace_run(request_json, id, out, cap);
        return;
    }
    /* The transition plane's reader (P5). The same four subcommands
       behind one `op`, and the same shape of thing — a ring an optional
       resident fills inside an armed process. It is a SAMPLER: it catches
       what a 2.2 s poll misses because the guest's event loop is ~60 Hz,
       and something raised and dismissed between two passes is still
       missed. See contract/event_tail.h. */
    if (strcmp(name, "transitions") == 0) {
        now_transitions_run(request_json, id, out, cap);
        return;
    }
    /* The reference layer. Each of these writes its whole command.result
       itself, so registering one is a table row and a call - see
       observe.h, which states this list exactly. */
    if (strcmp(name, "observe") == 0) {
        now_observe_command(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "handle") == 0) {
        now_observe_handle_command(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "axtree") == 0) {
        now_observe_axtree_command(request_json, id, out, cap);
        return;
    }
    if (strcmp(name, "axsnap") == 0) {
        now_observe_axsnap_command(request_json, id, out, cap);
        return;
    }
    snprintf(out, cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
             "\"error\":{\"code\":\"unknown-command\","
             "\"message\":\"%s is not a command this Mac knows\"}}",
             id, name);
}
