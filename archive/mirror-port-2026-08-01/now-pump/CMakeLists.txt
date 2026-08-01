# now-pump - the act plane's posting context (docs/resident-components.md,
# Tier B). A faceless 68K background application; see src/main.c for why it
# exists at all and why it is 68K on a PowerPC machine.
#
#   cmake -S now-pump -B build-pump -G Ninja \
#     -DCMAKE_TOOLCHAIN_FILE=$RETRO68_68K/m68k-apple-macos/cmake/retro68.toolchain.cmake
#   cmake --build build-pump
#
# scripts/build-guests builds it as a fourth artifact, with the 68K
# toolchain, beside NOW-68K and the extension.
cmake_minimum_required(VERSION 3.13)
project(NowPump C)

# 68K by design, not by convenience: the property this whole component
# buys is that a CLASSIC application's WaitNextEvent reaches the classic
# Event Manager. A PowerPC build would be the Carbon problem again in a
# different binary. Fail loudly rather than produce a wrong-runtime one.
if(NOT CMAKE_C_COMPILER MATCHES "m68k")
    message(FATAL_ERROR
        "now-pump is a classic 68K application - that is the point of it "
        "(src/main.c). Point CMAKE_TOOLCHAIN_FILE at the m68k Retro68 "
        "toolchain.")
endif()

# Creator 'NWpu', distinct from the application's 'NOWo' and the
# extension's 'NOWx'. The application finds this binary by CREATOR rather
# than by file name when it launches it: a name is something a human can
# change with one click in the Finder, and a launcher that guesses at a
# name fails in a way that looks exactly like a missing component.
add_application(now-pump
    TYPE "APPL"
    CREATOR "NWpu"
    src/main.c
    # The decisions - the click route, the ticket handshake, the session
    # clock - are the SAME file the extension and the application compile,
    # and the same one the host cc runs under test. This process makes no
    # decision of its own; that is what keeps a component nobody can watch
    # running inside the reach of a test.
    ../now-guest-shared/src/now_act_guard.c
    now-pump.r
)

target_include_directories(now-pump PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../contract
    ${CMAKE_CURRENT_SOURCE_DIR}/../now-guest-shared/src)

# -mcpu=68000: this runs on the whole 8.6-9.2.2 range, including under the
# 68K emulator on a PowerPC Mac, which is in fact where it usually runs.
# The warning gate matches every other target here for the same reason:
# now_act_guard.c was developed under it and a build that dropped it would
# be a weaker gate on shared code than the one it is compiled by elsewhere.
target_compile_options(now-pump PRIVATE -mcpu=68000 -O2 -Wall -Wextra -Werror)
