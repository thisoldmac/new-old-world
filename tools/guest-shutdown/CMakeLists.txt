cmake_minimum_required(VERSION 3.13)

# NOW Shut Down - the guest half of the emulator rig's cold reboot.
#
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=\
#     ~/Lab/Tools/Retro68-build-68k/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake \
#     tools/guest-shutdown
#   cmake --build build            # -> NowShutDown.bin (MacBinary)
#
# An INSTRUMENT, not part of the product: it is staged onto a
# session-private emulator clone by tools/stage-ext.py, launched through
# the anchor worker by tools/shutdown-guest.py, and it ships to nobody.
# The reasoning, and the three routes it replaces, are in src/now_shutdown.c.
#
# 68K, like ext/ and for the same kind of reason: the Shutdown Manager is
# CALL_NOT_IN_CARBON, so the Carbon toolchain the application uses cannot
# compile ShutDwnPower at all. A 68K application runs perfectly well on the
# PowerPC guest under the 68K emulator, and the 68K toolchain is already a
# prerequisite here because the extension needs it.

project(NowShutDown C)

if(NOT CMAKE_C_COMPILER MATCHES "m68k")
    message(FATAL_ERROR
        "tools/guest-shutdown needs the m68k Retro68 toolchain: the "
        "Shutdown Manager is CALL_NOT_IN_CARBON and does not exist in the "
        "retrocarbon headers the application builds against.")
endif()

add_application(NowShutDown
    TYPE "APPL"
    CREATOR "NOWs"
    src/now_shutdown.c)

target_compile_options(NowShutDown PRIVATE -mcpu=68000 -Wall -Wextra -Werror -Os)
