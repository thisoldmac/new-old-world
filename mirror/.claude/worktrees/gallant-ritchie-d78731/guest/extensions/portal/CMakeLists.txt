cmake_minimum_required(VERSION 3.13)
# TBT Portal — the in-process agent.
#
# AXPeek proved that a GNEFilter INIT runs inside every application's context
# and used it to READ per-process Toolbox roots. The Portal uses the same window
# to ACT: the host posts a request addressed to a target A5 world, and the hook
# serves it the next time it finds itself running as that process.
#
# Build with the *68K* Retro68 toolchain (an INIT is 68K code even on a PowerPC
# machine — and being 68K is also what lets the hook call a menu's 68K MDEF
# directly, with no Mixed Mode):
#
#   cmake -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE=\
#     ~/Lab/Tools/Retro68-build-68k/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake
#   cmake --build build
project(TBTPortal C ASM)

add_executable(Portal
    src/portal.c
    src/ptgne.S
    src/ptshared.h)

set_target_properties(Portal PROPERTIES
    OUTPUT_NAME Portal.flt
    LINK_FLAGS -Wl,--mac-flat)

add_custom_command(
    OUTPUT Portal.bin Portal.dsk
    COMMAND ${REZ} -I${REZ_INCLUDE_PATH}
                   ${CMAKE_CURRENT_SOURCE_DIR}/src/Portal.r
                   -o Portal.bin
                   --cc Portal.dsk
                   -t INIT -c TBTp
    DEPENDS Portal src/Portal.r)

add_custom_target(Portal_INIT ALL DEPENDS Portal.dsk)
