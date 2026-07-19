#include "commands.h"

#include <Carbon.h>

#include <stdio.h>
#include <string.h>

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
    char buf[56];
    Boolean has_ot;
    long phys_mb = 0, log_mb = 0;

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

/* --- wire path: serialize the rows to grouped JSON ---------------------- */

static void append_escaped(char *out, long cap, long *pos, const char *s)
{
    while (*s != '\0' && *pos + 2 < cap) {
        if (*s == '"' || *s == '\\') {
            out[(*pos)++] = '\\';
        }
        out[(*pos)++] = *s++;
    }
}

static void run_gestalt(long id, char *out, long cap)
{
    GestaltRow rows[kGestaltMaxRows];
    int count = now_gestalt_gather(rows, kGestaltMaxRows);
    long pos = 0;
    int i;
    /* every group, in a stable order, snapshot first */
    static const char *const groups[] = {
        "snapshot", "cpu", "memory", "os", "network", "hw", NULL
    };
    int g;
    Boolean first_group = true;

    pos += snprintf(out, cap,
                    "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                    "\"output\":{", id);
    for (g = 0; groups[g] != NULL; ++g) {
        Boolean first_row = true;
        for (i = 0; i < count; ++i) {
            if (strcmp(rows[i].group, groups[g]) != 0) {
                continue;
            }
            if (first_row) {
                if (!first_group) {
                    out[pos++] = ',';
                }
                pos += snprintf(out + pos, cap - pos, "\"%s\":[", groups[g]);
                first_group = false;
                first_row = false;
            } else {
                out[pos++] = ',';
            }
            out[pos++] = '[';
            out[pos++] = '"';
            append_escaped(out, cap, &pos, rows[i].label);
            out[pos++] = '"';
            out[pos++] = ',';
            out[pos++] = '"';
            append_escaped(out, cap, &pos, rows[i].value);
            out[pos++] = '"';
            out[pos++] = ']';
        }
        if (!first_row) {
            out[pos++] = ']';
        }
    }
    if (pos + 3 < cap) {
        out[pos++] = '}';
        out[pos++] = '}';
        out[pos] = '\0';
    } else {
        out[cap - 1] = '\0';
    }
}

void now_command_run(const char *name, long id, char *out, long cap)
{
    if (strcmp(name, "gestalt") == 0) {
        run_gestalt(id, out, cap);
        return;
    }
    snprintf(out, cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
             "\"error\":{\"code\":\"unknown-command\","
             "\"message\":\"%s is not a command this guest knows\"}}",
             id, name);
}
