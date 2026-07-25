# NOW-68K: guest client for the PowerBook 180c (System 7.1, 4 MB, MacTCP-only
# - Open Transport cannot link on Retro68 68K, ASLM). Modeled on
# appe/CMakeLists.txt, but this app IS the user-facing window (APPL, not
# 'appe'; backgroundAndForeground in guest68k.r, not onlyBackground), so it
# Finder-launches and double-clicks like a normal application.
#
#   cmake -S guest68k -B build-68k -G Ninja \
#     -DCMAKE_TOOLCHAIN_FILE=$RETRO68_68K/m68k-apple-macos/cmake/retro68.toolchain.cmake
#   cmake --build build-68k
cmake_minimum_required(VERSION 3.13)
project(Now68kGuest C)

# 68K-only by design (target-runtime contract at the top of this file's
# companion docs): a PPC branch has nothing to build here, so fail loudly
# rather than silently produce a wrong-ISA or empty target.
if(NOT CMAKE_C_COMPILER MATCHES "m68k")
    message(FATAL_ERROR
        "guest68k targets the PowerBook 180c (68030, System 7.1) only. "
        "Point CMAKE_TOOLCHAIN_FILE at the m68k Retro68 toolchain.")
endif()

add_application(now68k-guest
    TYPE "APPL"
    CREATOR "NW68"
    src/main.c
    src/window.c
    src/log.c
    src/frame.c
    src/json_scan.c
    src/numfmt.c
    src/hello.c
    src/ping.c
    src/n68_linesplit.c
    src/n68_console_ring.c
    src/n68_reader.c
    src/connfields.c
    src/net_mactcp.c
    src/wire68.c
    src/health.c
    src/commands68.c
    src/proc_quit_args.c
    src/proc68.c
    guest68k.r
)

target_include_directories(now68k-guest PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src)

# Retro68/CMake defaults to -O0 when no optimization level is set, which
# would make every later size/timing measurement on this milestone
# meaningless - set it explicitly rather than inheriting a default.
#
# The warning gate is not optional here. The pure-C units were developed on
# the host under -Wall -Wextra -Werror and one of their real bugs was caught
# by -Werror alone; moving those files in-tree without the same gate would
# silently drop it. It already has something to say about this shell.
target_compile_options(now68k-guest PRIVATE -O2 -Wall -Wextra -Werror)

# 68K resolves everything from InterfaceLib traps (Event/Window/Menu/TextEdit/
# Dialog/AppleEvent Managers, File Manager via libc's stdio shim, Device
# Manager for net_mactcp.c's .IPP calls) - no extra link libraries, matching
# appe's m68k branch.
