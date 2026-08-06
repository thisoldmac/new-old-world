cmake_minimum_required(VERSION 3.13)

# NOW GWorld - the isolated spike under the GWorld probe
# (docs/gworld-probe-brief.md), answering the two questions the probe
# itself cannot separate.
#
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=\
#     ~/Lab/Tools/Retro68-build-68k/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake \
#     tools/guest-gworld
#   cmake --build build            # -> NowGWorld.bin (MacBinary)
#
# An INSTRUMENT, not part of the product. Staged onto a session-private
# emulator clone, launched through the anchor worker, and it ships to
# nobody. It writes its findings to a text file the rig pulls back off
# the guest, because a result a person has to read off a screenshot is a
# result nobody can diff.
#
# WHY IT IS SEPARATE FROM THE PROBE. The probe hooks another process's
# offscreen port, which needs discovery to work before the mechanism can
# be tested at all - so a null result there has two explanations and the
# 2026-08-06 run could not tell them apart. This owns both ends: it
# allocates the GWorld, hooks it in its OWN context, and draws into it.
# If the bottlenecks do not fire here they fire nowhere, and that is the
# brief's outcome 3 for every application at once.
#
# 68K, like ext/ and the other two rig applets, and here the dialect is
# load-bearing rather than convenient: the real implementation lives in
# the 68K extension, where a QD proc UPP is a plain pointer, and the
# finding carbon-upp-is-not-a-cast-on-cfm says the CFM side is NOT the
# same. A spike in the wrong dialect would prove the wrong thing.

project(NowGWorld C)

if(NOT CMAKE_C_COMPILER MATCHES "m68k")
    message(FATAL_ERROR
        "tools/guest-gworld needs the m68k Retro68 toolchain, the same one "
        "ext/ and the other rig applets build with: this spike exists to "
        "measure the extension's dialect, not the application's.")
endif()

add_application(NowGWorld
    TYPE "APPL"
    CREATOR "NOWg"
    src/now_gworld.c)

target_compile_options(NowGWorld PRIVATE -mcpu=68000 -Wall -Wextra -Werror -Os)
