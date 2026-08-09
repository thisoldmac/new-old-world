#include "development_command.h"

#include <stdio.h>
#include <string.h>

#include "development_toolchain_mac.h"
#include "json.h"
#include "prefs.h"

static long add_row(char *out, long cap, long pos, const char *label,
                    const char *value, int comma)
{
    char escaped_label[96];
    char escaped_value[192];
    now_json_escape(label, escaped_label, sizeof escaped_label);
    now_json_escape(value, escaped_value, sizeof escaped_value);
    return pos + snprintf(out + pos, (size_t)(cap - pos),
        "%s[\"%s\",\"%s\"]", comma ? "," : "",
        escaped_label, escaped_value);
}

void now_development_command(long id, char *out, long cap)
{
    NowPrefs prefs;
    DevToolchain toolchain;
    long pos;
    int qualified = 0;

    now_prefs_load(&prefs);
    memset(&toolchain, 0, sizeof toolchain);
    if (prefs.toolchain_vref != 0 && prefs.toolchain_dir != 0) {
        qualified = dev_toolchain_measure(prefs.toolchain_vref,
            prefs.toolchain_dir, &toolchain) == noErr;
    }
    pos = snprintf(out, (size_t)cap,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
        "\"output\":{\"development\":[", id);
    pos = add_row(out, cap, pos, "Projects",
        prefs.projects_dir != 0 ? "chosen" : "not chosen", 0);
    pos = add_row(out, cap, pos, "Toolchain",
        prefs.toolchain_dir != 0 ? toolchain.id : "not registered", 1);
    pos = add_row(out, cap, pos, "Version",
        prefs.toolchain_dir != 0 ? toolchain.version : "unavailable", 1);
    pos = add_row(out, cap, pos, "Qualification",
        qualified ? "qualified" : (prefs.toolchain_dir != 0
            ? "refused" : "unavailable"), 1);
    pos = add_row(out, cap, pos, "ToolServer",
        toolchain.toolserver_found ? "found" : "not found", 1);
    pos = add_row(out, cap, pos, "MrC",
        toolchain.compiler_found ? "found" : "not found", 1);
    snprintf(out + pos, (size_t)(cap - pos), "]}}");
}
