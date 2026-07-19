#include "commands.h"

#include <Carbon.h>

#include <stdio.h>
#include <string.h>

static void format_bcd_version(long bcd, char *out, long cap)
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

static void run_gestalt(long id, char *out, long cap)
{
    long value = 0;
    char system[16] = "?";
    char carbon[16] = "?";
    long machine = 0;
    long ram_mb = 0;

    if (Gestalt(gestaltSystemVersion, &value) == noErr) {
        format_bcd_version(value, system, sizeof system);
    }
    if (Gestalt(gestaltMachineType, &value) == noErr) {
        machine = value;
    }
    if (Gestalt(gestaltPhysicalRAMSize, &value) == noErr) {
        ram_mb = value / (1024L * 1024L);
    }
    if (Gestalt('cbon', &value) == noErr) {
        format_bcd_version(value, carbon, sizeof carbon);
    }
    snprintf(out, cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"system\":\"%s\",\"machineType\":\"%ld\","
             "\"ramMB\":\"%ld\",\"carbonLib\":\"%s\"}}",
             id, system, machine, ram_mb, carbon);
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
