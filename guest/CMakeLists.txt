cmake_minimum_required(VERSION 3.13)
project(ScreenshotsGuest C)

add_application(screenshot-guest
    CREATOR "ScPt"
    src/main.c
    src/capture.c
    src/capture_store.c
    resources/app.r
)

target_include_directories(screenshot-guest PRIVATE src)
target_compile_options(screenshot-guest PRIVATE
    -Wall
    -Wextra
    -Werror
)

