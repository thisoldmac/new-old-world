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
include_directories(${CMAKE_CURRENT_BINARY_DIR})

set(_identity_header ${CMAKE_CURRENT_BINARY_DIR}/now_ext_build_identity.h)
set(_identity_rez ${CMAKE_CURRENT_BINARY_DIR}/now_ext_identity.r)
add_custom_target(generate_now_ext_identity ALL
    COMMAND ${CMAKE_COMMAND}
            -DSRC_DIR=${CMAKE_CURRENT_SOURCE_DIR}/src
            -DCONTRACT=${CMAKE_CURRENT_SOURCE_DIR}/../contract/peek_table.h
            -DHEADER=${_identity_header}
            -DREZ_OUT=${_identity_rez}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/build_identity.cmake
    BYPRODUCTS ${_identity_header} ${_identity_rez}
    VERBATIM)

# The content plane (P3) is two translation units on purpose, and the
# split is the charter's ("planes talk only through the core", and
# docs/resident-components.md's list of what is never resident):
#   now_content_logic.c - no Toolbox, so a host cc runs its decisions
#                         (scripts/test-native, content_plane_test.c);
#   now_content.c       - the hooks, and nothing that could have lived
#                         in the file above.
add_executable(NowExt
    src/now_ext.c
    src/now_ext_core_logic.c
    src/now_semantic.c
    src/now_semantic_logic.c
    src/now_ext_gne.S
    src/now_content.c
    src/now_event.c
    src/now_event_logic.c
    src/now_content_logic.c
    src/now_liveness.c
    # P6's channel - the resident's own connection to the host. A separate
    # translation unit from the vehicle above on purpose: that file's
    # recovery procedure is "disarm it here", and a transport mixed into
    # it would make the one thing that must stay easy to switch off
    # harder to find.
    src/now_liveness_net.c
    # P6's entry shim. A Time Manager task is a REGISTER-based callback
    # (its record arrives in A1), so it needs assembly for exactly the
    # reason the jGNE filter above does - the file's header carries the
    # finding and the boot hang it explains.
    src/now_liveness_tm.S
    # P4, the act plane: its own translation unit and its own six trap
    # trampolines. Separate files, no cross-plane calls - review enforces
    # what tbt's sibling INIT binaries used to.
    src/now_ext_act.c
    src/now_ext_act_patch.S
    # P7, the drag vehicle. Its own translation unit for the reason the
    # liveness pair are two: this is the file that can leave a machine
    # holding the mouse button, so it must be the file you can find.
    # No trap patches at all - four low-memory writes and a deadline.
    src/now_ext_drag.c
    src/now_ext_drag_tm.S
    # P8, the cursor plane, and its two Cursor Device Manager calls.
    # Its own translation unit because it is the one place in this
    # extension that owns the DRAWN pointer, and because the assembly
    # beside it exists only because CursorDevices.h declares the whole
    # manager as TWOWORDINLINE traps this compiler ignores.
    src/now_ext_cursor.c
    src/now_ext_cursor_cdm.S
    src/now_content_qdext.S
    ../now-guest-shared/src/now_act_guard.c
    # P7's decisions, where the host cc can compile them and
    # scripts/test-native can watch the dead-man fire.
    ../now-guest-shared/src/now_drag_logic.c
    # P8's one decision - "is somebody else driving this pointer" - where
    # the host cc can compile it and a test can watch it yield.
    ../now-guest-shared/src/now_cursor_logic.c
    ../now-guest-shared/src/now_semantic_guard.c)
add_dependencies(NowExt generate_now_ext_identity)
set_source_files_properties(src/now_ext.c
    PROPERTIES OBJECT_DEPENDS ${_identity_header})

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
    COMMAND ${REZ} -I${REZ_INCLUDE_PATH} -I${CMAKE_CURRENT_BINARY_DIR}
                   ${CMAKE_CURRENT_SOURCE_DIR}/src/now_ext.r
                   -o NowExt.bin
                   --cc NowExt.dsk
                   -t INIT -c NOWx
    DEPENDS NowExt src/now_ext.r ${_identity_rez})

add_custom_target(NowExt_INIT ALL DEPENDS NowExt.dsk)

find_program(PYTHON3_EXECUTABLE NAMES python3 python)
if(PYTHON3_EXECUTABLE)
    add_custom_command(
        OUTPUT NowExt.bin.now-update.json
        COMMAND ${PYTHON3_EXECUTABLE}
                "${CMAKE_CURRENT_SOURCE_DIR}/../tools/write-update-manifest.py"
                --artifact NowExt.bin
                --component extension
                --version-header
                    "${CMAKE_CURRENT_SOURCE_DIR}/../contract/resident_version.h"
                --version-major NOW_RESIDENT_VERSION_MAJOR
                --version-minor NOW_RESIDENT_VERSION_MINOR
                --identity-header "${_identity_header}"
                --identity-word-prefix NOW_EXT_BUILD_FINGERPRINT_
        DEPENDS NowExt.bin ${_identity_header}
                "${CMAKE_CURRENT_SOURCE_DIR}/../tools/write-update-manifest.py"
        COMMENT "Writing extension update identity"
        VERBATIM)
    add_custom_target(NowExt_update_manifest ALL
        DEPENDS NowExt.bin.now-update.json)
endif()
