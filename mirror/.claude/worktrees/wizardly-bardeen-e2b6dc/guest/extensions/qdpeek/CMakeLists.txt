cmake_minimum_required(VERSION 3.13)
# TBT QDPeek — 68K resident QuickDraw-capture INIT (QDPEEK-SPEC.md).
# Sibling to AXPeek: installs custom CQDProcs on a traced app's window ports to
# capture its QuickDraw operations, published via Gestalt('TBqd') for the
# toolkit worker's `qdtrace` verb.
#
# Build with the *68K* Retro68 toolchain (the INIT is 68K code; RoutineDescriptor
# hooks let native Color QD call it via Mixed Mode):
#
#   cmake -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE=\
#     ~/Lab/Tools/Retro68-build-68k/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake
#   cmake --build build
#
# Produces QDPeek.bin (MacBinary, harness `put` channel) and QDPeek.dsk.
project(TBTQDPeek C ASM)

add_executable(QDPeek
    src/qdpeek.c
    src/qdgne.S
    src/qdshared.h)

set_target_properties(QDPeek PROPERTIES
    OUTPUT_NAME QDPeek.flt
    LINK_FLAGS -Wl,--mac-flat)

add_custom_command(
    OUTPUT QDPeek.bin QDPeek.dsk
    COMMAND ${REZ} -I${REZ_INCLUDE_PATH}
                   ${CMAKE_CURRENT_SOURCE_DIR}/src/QDPeek.r
                   -o QDPeek.bin
                   --cc QDPeek.dsk
                   -t INIT -c TBTq
    DEPENDS QDPeek src/QDPeek.r)

add_custom_target(QDPeek_INIT ALL DEPENDS QDPeek.dsk)
