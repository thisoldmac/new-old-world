cmake_minimum_required(VERSION 3.13)
project(NowGuest C)

add_application(now-guest
    CREATOR "NOWo"
    src/main.c
    src/commands.c
    src/console_win.c
    src/capture.c
    src/screenshot.c
    src/shots_panel.c
    src/ot_carbon.c
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

