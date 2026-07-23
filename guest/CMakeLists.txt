cmake_minimum_required(VERSION 3.13)
project(NowGuest C)

add_application(now-guest
    CREATOR "NOWo"
    src/main.c
    src/commands.c
    src/console_model.c
    src/console_module.c
    src/capture.c
    src/fileshare.c
    src/pump.c
    src/build_stamp.c
    src/screenshot.c
    src/vprobe.c
    src/catsearch.c
    src/software.c
    src/sw_vers_parse.c
    src/software_layout.c
    src/software_module.c
    src/pixels.c
    src/screenshots_module.c
    src/census_module.c
    src/census_probes.c
    src/census_trap.c
    src/logs_module.c
    src/census_decode.c
    src/census_report.c
    src/files_module.c
    src/files_browser_view.c
    src/files_share_view.c
    src/confirm.c
    src/ot_carbon.c
    src/json.c
    src/nowlog.c
    src/wire.c
    src/prefs.c
    src/conn_fields.c
    src/conn_edit_dialog.c
    src/connection_module.c
    src/peek.c
    src/peek_validate.c
    src/peek_read.c
    src/proc_actions.c
    src/processes_layout.c
    src/processes_module.c
    src/workshop_layout.c
    src/workshop_sidebar.c
    src/workshop_window.c
    resources/app.r
)

# contract/ carries the in-memory table header shared with the (future)
# 68K extension build - the wire contract's sibling.
target_include_directories(now-guest PRIVATE src ../contract)
target_compile_options(now-guest PRIVATE
    -Wall
    -Wextra
    -Werror
)


# The probe times tight read loops; at -O0 loop overhead pollutes the
# bandwidth numbers.
set_source_files_properties(src/vprobe.c PROPERTIES COMPILE_OPTIONS "-O2")

# The build stamp is only honest if it is recompiled every build.
add_custom_target(touch_build_stamp ALL
    COMMAND ${CMAKE_COMMAND} -E touch_nocreate
            ${CMAKE_CURRENT_SOURCE_DIR}/src/build_stamp.c)
add_dependencies(now-guest touch_build_stamp)

# The canonical deploy artifact carries the product's real name, spaces
# and all: "New Old World.bin", to match "New Old World.app" on the host.
# A classic HFS name allows the spaces; a CMake target name does not, and
# Retro68 names the MacBinary after the target - so the name is stamped
# into a copy of the .bin here instead. This is not cosmetic: Rumpus
# decodes the .bin by its INTERNAL name, and prefs.c keys the canonical
# preferences (and the real host, not the 10.0.2.2 emulator gateway) off
# that process name. now-guest.bin stays for dev / side-by-side testing;
# "New Old World.bin" is the one that goes to metal and lands on main.
find_program(PYTHON3_EXECUTABLE NAMES python3 python)
if(PYTHON3_EXECUTABLE)
    add_custom_command(
        OUTPUT "New Old World.bin"
        COMMAND ${PYTHON3_EXECUTABLE}
                "${CMAKE_CURRENT_SOURCE_DIR}/tools/name_macbinary.py"
                "now-guest.bin" "New Old World.bin" "New Old World"
        DEPENDS now-guest.bin
                "${CMAKE_CURRENT_SOURCE_DIR}/tools/name_macbinary.py"
        COMMENT "Stamping canonical MacBinary: New Old World.bin"
        VERBATIM)
    add_custom_target(now-guest-canonical ALL DEPENDS "New Old World.bin")
else()
    message(WARNING
        "python3 not found: skipping the canonical 'New Old World.bin' "
        "stamp; deploy now-guest.bin renamed by hand (see AGENTS.md).")
endif()
