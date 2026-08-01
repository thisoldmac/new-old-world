# Retro68 build of the mirror agent — a faceless PPC/CFM application for
# Mac OS 9.1. Configure with the Retro68 PowerPC toolchain:
#
#   cmake -S . -B build -G Ninja \
#     -DCMAKE_TOOLCHAIN_FILE=$RETRO68/powerpc-apple-macos/cmake/retroppc.toolchain.cmake
#   ninja -C build
#
# Products: build/mirror-agent.bin (MacBinary, for a `put`-channel deploy) and
# build/mirror-agent.dsk (CD-insert deploy).
#
# PPC only, deliberately. Open Transport cannot link under Retro68 for 68K
# (ASLM), so a 68K port would have to speak MacTCP — a different transport with
# its own wedge history. One ISA, one transport, until a second machine earns
# the second one.
cmake_minimum_required(VERSION 3.13)
project(MirrorAgent C)

if(CMAKE_C_COMPILER MATCHES "m68k")
    message(FATAL_ERROR
        "The mirror agent is PPC-only: Open Transport does not link under "
        "Retro68 for 68K (ASLM). Use the PowerPC toolchain file.")
endif()

set(SRC ${CMAKE_CURRENT_SOURCE_DIR}/src)

# Version identity: VERSION is the single source of truth, injected build-wide
# so `hello` and `ping` report *which* build is running — the answer to "is this
# the stale one I deployed an hour ago?"
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" MIRROR_VERSION LIMIT_COUNT 1)
string(STRIP "${MIRROR_VERSION}" MIRROR_VERSION)
execute_process(
    COMMAND git rev-parse --short=8 HEAD
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    OUTPUT_VARIABLE MIRROR_GIT_REV OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET)
message(STATUS "Mirror agent version ${MIRROR_VERSION} (${MIRROR_GIT_REV})")

# Build identity that cannot go stale. `__DATE__ __TIME__` in one translation
# unit reports when THAT file was compiled, so a main.c-only change shipped a
# binary whose stamp was unchanged and a deploy could not be confirmed. The
# stamp is now a hash over every source, regenerated on every build (the header
# is only rewritten when it actually differs, so nothing rebuilds needlessly).
set(MIRROR_STAMP_HEADER ${CMAKE_CURRENT_BINARY_DIR}/mirrorbuildstamp.h)
add_custom_target(mirror-buildstamp ALL
    BYPRODUCTS ${MIRROR_STAMP_HEADER}
    COMMAND ${CMAKE_COMMAND}
            -DSRC_DIR=${SRC} -DOUT=${MIRROR_STAMP_HEADER}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/buildstamp.cmake
    COMMENT "Hashing sources for the build stamp")
# Generate it once at configure time too, so the very first compile has a header.
execute_process(COMMAND ${CMAKE_COMMAND}
    -DSRC_DIR=${SRC} -DOUT=${MIRROR_STAMP_HEADER}
    -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/buildstamp.cmake)

add_application(mirror-agent
    ${SRC}/main.c
    ${SRC}/mirrorverbs.c
    ${SRC}/wire.c
    ${SRC}/xfer_crc.c
    ${SRC}/xfer_state.c
    ${SRC}/macbin.c
    ${SRC}/ot.c
    ${SRC}/ot_sched.c
    ${SRC}/axwalk.c
    ${SRC}/axmenu.c
    ${SRC}/axtext.c
    ${SRC}/axref.c
    ${SRC}/axresolve.c
    ${SRC}/axbinding.c
    ${SRC}/axoracle.c
    ${SRC}/mirror.r
)

target_include_directories(mirror-agent PRIVATE ${SRC} ${CMAKE_CURRENT_BINARY_DIR})
add_dependencies(mirror-agent mirror-buildstamp)

# Optimised code, always: with no explicit level Retro68/CMake builds -O0, which
# is invisible in an I/O-bound verb but shows up plainly in a bounded walk's
# tick budget — a walk that fits at -O2 can blow its ceiling at -O0 and return
# a partial tree that looks like a cap.
target_compile_options(mirror-agent PRIVATE -O2)

target_compile_definitions(mirror-agent PRIVATE
    MIRROR_VERSION="${MIRROR_VERSION}"
    MIRROR_GIT_REV="${MIRROR_GIT_REV}"
    TBT_BACKING="mirror")

# PPC/CFM needs the app glue plus the Open Transport import stubs.
target_link_libraries(mirror-agent
    OpenTransportAppPPC
    OpenTransportLib
    OpenTptInternetLib)
