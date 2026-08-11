cmake_minimum_required(VERSION 3.13)

# CursorRig - the spike's resident writer. A 68K INIT, built with the
# *68K* Retro68 toolchain (an INIT is 68K even on a PowerPC machine;
# that is a property of classic Mac OS, not a choice):
#
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=\
#     ~/Lab/Tools/Retro68-build-68k/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake init
#   cmake --build build
#
# Produces CursorRig.bin (MacBinary) and CursorRig.dsk. Deploy the .bin
# into System Folder:Extensions and COLD-boot: an INIT loads at boot
# only, and OS 9 ignores a soft power-down.

project(CursorRig C ASM)

include_directories(${CMAKE_CURRENT_SOURCE_DIR}/../contract)

# The build identity, regenerated every build (see
# tools/gen_build_id.py): a stale resident is otherwise
# indistinguishable from a live one, and the host refuses to measure a
# build it did not stage.
set(RIG_INIT_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/src/rig_init.c
    ${CMAKE_CURRENT_SOURCE_DIR}/src/rig_tm.S
    ${CMAKE_CURRENT_SOURCE_DIR}/src/rig_gne.S
    ${CMAKE_CURRENT_SOURCE_DIR}/src/rig_patch.S
    ${CMAKE_CURRENT_SOURCE_DIR}/src/rig_cursor.S
    ${CMAKE_CURRENT_SOURCE_DIR}/../contract/cursor_rig_logic.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../contract/cursor_rig.h)
add_custom_target(CursorRig_buildid ALL
    COMMAND python3 ${CMAKE_CURRENT_SOURCE_DIR}/../tools/gen_build_id.py
            ${CMAKE_CURRENT_BINARY_DIR}/rig_build_stamp.c
            ${CMAKE_CURRENT_BINARY_DIR}/CursorRig.buildid
            kRigBuildId ${RIG_INIT_SOURCES}
    BYPRODUCTS ${CMAKE_CURRENT_BINARY_DIR}/rig_build_stamp.c
    COMMENT "stamping the resident's build identity")

add_executable(CursorRig
    ${CMAKE_CURRENT_BINARY_DIR}/rig_build_stamp.c
    src/rig_init.c
    src/rig_tm.S
    src/rig_gne.S
    src/rig_patch.S
    src/rig_cursor.S
    ../contract/cursor_rig_logic.c)

# -mcpu=68000: the rig must run wherever the guest does, including a
# 68K-emulated PowerPC. Flat code resource, with a map.
target_compile_options(CursorRig PRIVATE -mcpu=68000 -Wall -Wextra -Werror -Os)
set_target_properties(CursorRig PROPERTIES
    OUTPUT_NAME CursorRig.flt
    LINK_FLAGS "-Wl,--mac-flat -Wl,-Map,CursorRig.map")

# INIT 128 in a file of type INIT, creator 'CRig'.
add_custom_command(
    OUTPUT CursorRig.bin CursorRig.dsk
    COMMAND ${REZ} -I${REZ_INCLUDE_PATH}
                   ${CMAKE_CURRENT_SOURCE_DIR}/src/rig_init.r
                   -o CursorRig.bin
                   --cc CursorRig.dsk
                   -t INIT -c CRig
    DEPENDS CursorRig src/rig_init.r)

add_dependencies(CursorRig CursorRig_buildid)
add_custom_target(CursorRig_INIT ALL DEPENDS CursorRig.dsk)
