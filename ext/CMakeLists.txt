cmake_minimum_required(VERSION 3.13)

# The NOW Extension - the guest's optional resident component, plane P0
# (docs/resident-components.md). A 68K INIT; build with the *68K* Retro68
# toolchain, NOT the retrocarbon PPC one the application uses:
#
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=\
#     ~/Lab/Tools/Retro68-build-68k/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake ext
#   cmake --build build
#
# Produces NowExt.bin (MacBinary, deploy channel) and NowExt.dsk. Deploy
# NowExt.bin into System Folder:Extensions and COLD-boot: INITs load at
# boot only, and OS 9 ignores a soft power-down.

project(NowExtension C ASM)

# The shared table contract, compiled here exactly as the app and the
# host test compile it - the whole point of one header.
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/../contract)
# The act plane's decisions live in now-guest-shared so that the host cc
# compiles the SAME file the extension does. It is the one part of a
# resident component a native test can reach, and the guard it holds is
# the plane's whole safety argument - see now_act_guard.h.
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/../now-guest-shared/src)

add_executable(NowExt
    src/now_ext.c
    src/now_ext_gne.S
    # P4, the act plane: its own translation unit and its own six trap
    # trampolines. Separate files, no cross-plane calls - review enforces
    # what tbt's sibling INIT binaries used to.
    src/now_ext_act.c
    src/now_ext_act_patch.S
    ../now-guest-shared/src/now_act_guard.c)

# -mcpu=68000: the extension must run on the whole 8.6-9.2.2 range,
# including 68K-emulated PowerPC. Flat code resource, GC'd, with a map.
target_compile_options(NowExt PRIVATE -mcpu=68000 -Wall -Wextra -Werror -Os)
set_target_properties(NowExt PROPERTIES
    OUTPUT_NAME NowExt.flt
    LINK_FLAGS "-Wl,--mac-flat -Wl,-Map,NowExt.map")

# INIT 128 in a file of type INIT, creator 'NOWx' (the extension's own,
# distinct from the app's 'NOWo'). Rez reads the built flat blob.
add_custom_command(
    OUTPUT NowExt.bin NowExt.dsk
    COMMAND ${REZ} -I${REZ_INCLUDE_PATH}
                   ${CMAKE_CURRENT_SOURCE_DIR}/src/now_ext.r
                   -o NowExt.bin
                   --cc NowExt.dsk
                   -t INIT -c NOWx
    DEPENDS NowExt src/now_ext.r)

add_custom_target(NowExt_INIT ALL DEPENDS NowExt.dsk)
