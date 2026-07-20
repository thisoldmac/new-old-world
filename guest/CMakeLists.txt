cmake_minimum_required(VERSION 3.13)
project(NowGuest C)

add_application(now-guest
    CREATOR "NOWo"
    src/main.c
    src/commands.c
    src/console_win.c
    src/capture.c
    src/fileshare.c
    src/pump.c
    src/build_stamp.c
    src/screenshot.c
    src/vprobe.c
    src/pixels.c
    src/shots_panel.c
    src/share_panel.c
    src/ot_carbon.c
    src/json.c
    src/wire.c
    src/prefs.c
    src/settings_dialog.c
    resources/app.r
)

target_include_directories(now-guest PRIVATE src)
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
