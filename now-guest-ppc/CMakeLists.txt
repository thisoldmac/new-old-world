cmake_minimum_required(VERSION 3.13)
project(NowGuest C)

add_application(now-guest-ppc
    CREATOR "NOWo"
    src/main.c
    src/commands/cmd_help.c
    src/commands/cmd_line.c
    src/commands/commands.c
    src/commands/gestalt_json.c
    src/console/console_model.c
    src/console/console_module.c
    # Not under src/: one implementation both guests compile, the way
    # contract/ carries the headers both guests include. See its own
    # header for why the console history in particular is out here.
    ../now-guest-shared/src/console_history.c
    src/screenshots/capture.c
    src/files/fileshare.c
    src/core/pump.c
    src/core/build_stamp.c
    src/core/agent_access.c
    src/screenshots/screenshot.c
    src/census/vprobe.c
    src/files/catsearch.c
    src/software/software.c
    src/software/sw_vers_parse.c
    src/software/software_layout.c
    src/software/software_module.c
    src/screenshots/pixels.c
    src/screenshots/screenshots_module.c
    src/census/census_module.c
    src/census/census_probes.c
    src/census/census_trap.c
    src/logs/logs_module.c
    src/mcp/mcp_layout.c
    src/mcp/mcp_module.c
    src/diagnostics/diag_layout.c
    src/diagnostics/diagnostics_module.c
    src/census/census_decode.c
    src/census/census_report.c
    src/files/files_module.c
    src/files/files_browser_view.c
    src/files/files_share_view.c
    src/files/files_pull.c
    src/workshop/confirm.c
    src/core/ot_carbon.c
    src/core/json.c
    src/core/nowlog.c
    src/core/wire.c
    src/core/prefs.c
    src/connection/conn_fields.c
    src/connection/conn_edit_dialog.c
    src/connection/connection_module.c
    src/peek/peek.c
    src/peek/peek_validate.c
    src/peek/peek_oracle.c
    src/peek/peek_read.c
    src/processes/proc_actions.c
    src/processes/proc_quit_args.c
    src/processes/processes_layout.c
    src/processes/processes_module.c
    src/workshop/workshop_layout.c
    src/workshop/workshop_sidebar.c
    src/workshop/workshop_window.c
    src/scene/scene_build.c
    src/scene/scene_json.c
    src/scene/scene_collect.c
    src/scene/scene_walk.c
    # The foreign-memory walk, ported from this project's own prototype
    # (timbottu/mirror). Pure parsers plus one Toolbox binding; see
    # src/axwalk/axwalk.h for why its constants are evidence.
    src/axwalk/axwalk.c
    src/axwalk/axmenu.c
    src/axwalk/axtext.c
    src/axwalk/axresolve.c
    src/axwalk/axbinding.c
    src/axwalk/axprocess.c
    # The reference layer over that walk: minting the opaque references
    # every act verb addresses, and resolving one back to a live element
    # or refusing with the reason. The deciding half (obsref.c,
    # obsresolve.c) is Toolbox-free and natively tested; observe.c only
    # obtains. See src/observe/obsref.h on why a reference cannot be
    # forged, and obsresolve.h on why staleness is never repaired.
    src/observe/obsref.c
    src/observe/obsresolve.c
    src/observe/observe.c

    # P4, the act plane's application half. act_ref.c and act_args.c are
    # Toolbox-free and natively tested; act_client.c is the thin Toolbox
    # layer; act_cmds.c is the six commands. now_act_guard.c is SHARED
    # with the 68K extension - one file, both sides of the seam, which is
    # what lets the host cc test the guard that runs inside other
    # people's applications.
    src/act/act_ref.c
    src/act/act_args.c
    src/act/act_client.c
    src/act/act_cmds.c
    ../now-guest-shared/src/now_act_guard.c

    # The input plane: mouseloc (a read, and the instrument the act plane
    # is measured with), script (OSADoScript) and aesend (four core Apple
    # Events, a closed vocabulary rather than a class/id pipe).
    # input_args.c is Toolbox-free and natively tested - it holds the
    # timeout clamp, the CR conversion classic AppleScript needs, the
    # `entire contents` refusal, and the serials aesend will not address;
    # input_cmds.c is the thin Toolbox layer over it.
    src/input/input_args.c
    src/input/input_cmds.c
    resources/app.r
    # The application icon family, generated from the artwork by
    # assets/icons/classic/rez.py and shared with any other target that
    # wants it. Referenced where it is generated rather than copied in: a
    # copy is a second definition of a file whose own header says not to
    # hand-edit it, and the two would drift the first time the art moved.
    ../assets/icons/classic/now-icons.r
)

# src/ is split by domain (core/, commands/, workshop/, ...), but the
# sources include their headers by BARE NAME - "json.h", not "core/json.h".
# Which domain a header is filed under is a decision about where a human
# looks for it, and re-filing one should not touch every file that includes
# it, so every domain directory goes on the include path.
#
# GLOB rather than a hand-kept list because the two must never disagree: a
# list that missed a new domain would fail as "no such file", pointing at the
# include rather than at this line. Configure-time is the right time - adding
# a directory is already a re-run of cmake.
file(GLOB NOW_GUEST_SRC_DIRS LIST_DIRECTORIES true
     ${CMAKE_CURRENT_SOURCE_DIR}/src/*)
list(FILTER NOW_GUEST_SRC_DIRS EXCLUDE REGEX "\\.[ch]$")

# contract/ carries the in-memory table header shared with the 68K
# extension build - the wire contract's sibling.
target_include_directories(now-guest-ppc PRIVATE
    src ${NOW_GUEST_SRC_DIRS} ../contract ../now-guest-shared/src)
target_compile_options(now-guest-ppc PRIVATE
    -Wall
    -Wextra
    -Werror
)


# The probe times tight read loops; at -O0 loop overhead pollutes the
# bandwidth numbers.
set_source_files_properties(src/census/vprobe.c PROPERTIES COMPILE_OPTIONS "-O2")

# The build stamp is only honest if it is recompiled every build.
add_custom_target(touch_build_stamp ALL
    COMMAND ${CMAKE_COMMAND} -E touch_nocreate
            ${CMAKE_CURRENT_SOURCE_DIR}/src/core/build_stamp.c)
add_dependencies(now-guest-ppc touch_build_stamp)

# The canonical deploy artifact carries the product's real name, spaces
# and all: "New Old World.bin", to match "New Old World.app" on the host.
# A classic HFS name allows the spaces; a CMake target name does not, and
# Retro68 names the MacBinary after the target - so the name is stamped
# into a copy of the .bin here instead. This is not cosmetic: Rumpus
# decodes the .bin by its INTERNAL name, and prefs.c keys the canonical
# preferences (and the real host, not the 10.0.2.2 emulator gateway) off
# that process name. now-guest-ppc.bin stays for dev / side-by-side testing;
# "New Old World.bin" is the one that goes to metal and lands on main.
find_program(PYTHON3_EXECUTABLE NAMES python3 python)
if(PYTHON3_EXECUTABLE)
    add_custom_command(
        OUTPUT "New Old World.bin"
        COMMAND ${PYTHON3_EXECUTABLE}
                "${CMAKE_CURRENT_SOURCE_DIR}/tools/name_macbinary.py"
                "now-guest-ppc.bin" "New Old World.bin" "New Old World"
        DEPENDS now-guest-ppc.bin
                "${CMAKE_CURRENT_SOURCE_DIR}/tools/name_macbinary.py"
        COMMENT "Stamping canonical MacBinary: New Old World.bin"
        VERBATIM)
    add_custom_target(now-guest-ppc-canonical ALL DEPENDS "New Old World.bin")
else()
    message(WARNING
        "python3 not found: skipping the canonical 'New Old World.bin' "
        "stamp; deploy now-guest-ppc.bin renamed by hand (see AGENTS.md).")
endif()
