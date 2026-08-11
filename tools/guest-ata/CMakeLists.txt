cmake_minimum_required(VERSION 3.13)

# NOW ATA - an instrument that asks one Macintosh's drive to introduce
# itself, and carries its own control while doing it.
#
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=\
#     ~/Lab/Tools/Retro68-build-68k/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake \
#     tools/guest-ata
#   cmake --build build            # -> NowAta.bin (MacBinary)
#
# Ships to nobody. Copied onto a machine, double-clicked, read, deleted.
# The reasoning and what a null result means are in src/now_ata.c.
#
# 68K for the same reason guest-wedge is, plus one specific to this: the
# product reaches the ATA Manager from PowerPC through CallUniversalProc
# and a hand-built thunk, and a 68K application calls the trap directly.
# Removing that layer makes this a cleaner question about the DRIVE.

project(NowAta C)

if(NOT CMAKE_C_COMPILER MATCHES "m68k")
    message(FATAL_ERROR
        "tools/guest-ata needs the m68k Retro68 toolchain, the same one "
        "ext/ and tools/guest-wedge build with.")
endif()

add_application(NowAta
    TYPE "APPL"
    CREATOR "NOWa"
    src/now_ata.c)

target_compile_options(NowAta PRIVATE -mcpu=68000 -Wall -Wextra -Werror -Os)
