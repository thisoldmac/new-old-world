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
    src/pixels.c
    src/screenshots_module.c
    src/census_module.c
    src/census_probes.c
    src/census_trap.c
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
