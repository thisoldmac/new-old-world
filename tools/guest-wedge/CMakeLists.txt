cmake_minimum_required(VERSION 3.13)

# NOW Wedge - the guest half of the liveness rig: a Macintosh starving
# itself on purpose, for a bounded time, so 012's liveness work can be
# tested without hand-driving the Finder into a modal.
#
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=\
#     ~/Lab/Tools/Retro68-build-68k/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake \
#     tools/guest-wedge
#   cmake --build build            # -> NowWedge.bin (MacBinary)
#
# An INSTRUMENT, not part of the product: staged onto a session-private
# emulator clone and launched through the anchor worker by NAME, which is
# also how it is told what to do — "NOW Wedge spin 30". It ships to
# nobody. The reasoning, the three modes and what they each prove are in
# src/now_wedge.c.
#
# 68K, like ext/ and tools/guest-shutdown, for a simpler reason than
# theirs: it must starve the machine the way an ordinary application
# does, the 68K toolchain is already a prerequisite here, and a 68K
# application runs perfectly well on the PowerPC guest under the
# emulator. Nothing it calls is Carbon-forbidden.

project(NowWedge C)

if(NOT CMAKE_C_COMPILER MATCHES "m68k")
    message(FATAL_ERROR
        "tools/guest-wedge needs the m68k Retro68 toolchain, the same one "
        "ext/ and tools/guest-shutdown build with.")
endif()

add_application(NowWedge
    TYPE "APPL"
    CREATOR "NOWw"
    src/now_wedge.c)

target_compile_options(NowWedge PRIVATE -mcpu=68000 -Wall -Wextra -Werror -Os)
