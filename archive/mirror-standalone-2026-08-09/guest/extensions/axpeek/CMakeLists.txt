cmake_minimum_required(VERSION 3.13)
# TBT AXPeek — 68K resident pointer-oracle INIT for agents (docs/41, docs/46).
# A GNEFilter shim observes each active A5 world and publishes its WindowList
# anchors via Gestalt('TBax'); the toolkit worker consumes the bounded table.
#
# Build with the *68K* Retro68 toolchain (the INIT is 68K code; validate on the
# q800 68K rig first — no Mixed Mode — before any PPC machine):
#
#   cmake -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE=\
#     ~/Lab/Tools/Retro68-build-68k/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake
#   cmake --build build
#
# Produces AXPeek.bin (MacBinary, for the harness `put` channel) and
# AXPeek.dsk (CD-insert deploy). Pattern: Retro68 Samples/SystemExtension.
project(TBTAXPeek C ASM)

add_executable(AXPeek
    src/axpeek.c
    src/axgne.S
    src/axoracle.c
    src/axoracle.h
    src/axshared.h)

set_target_properties(AXPeek PROPERTIES
    OUTPUT_NAME AXPeek.flt
    LINK_FLAGS -Wl,--mac-flat)

add_custom_command(
    OUTPUT AXPeek.bin AXPeek.dsk
    COMMAND ${REZ} -I${REZ_INCLUDE_PATH}
                   ${CMAKE_CURRENT_SOURCE_DIR}/src/AXPeek.r
                   -o AXPeek.bin
                   --cc AXPeek.dsk
                   -t INIT -c TBTa
    DEPENDS AXPeek src/AXPeek.r)

add_custom_target(AXPeek_INIT ALL DEPENDS AXPeek.dsk)
