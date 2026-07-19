cmake_minimum_required(VERSION 3.13)
project(NowGuest C)

add_application(now-guest
    CREATOR "NOWo"
    src/main.c
    src/capture_win.c
    src/capture.c
    src/capture_store.c
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

