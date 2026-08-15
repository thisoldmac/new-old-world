cmake_minimum_required(VERSION 3.13)

# CursorRig Intake - the spike's PowerPC Carbon application. Built with
# the retrocarbon (PowerPC) toolchain, NOT the 68K one the INIT uses:
#
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=\
#     ~/Lab/Tools/Retro68-build/toolchain/powerpc-apple-macos/cmake/retrocarbon.toolchain.cmake app
#   cmake --build build
#
# Open Transport comes from libCarbonLib.a, which the toolchain links by
# default and which exports every symbol used here - checked rather than
# assumed, because the alternative (resolving them by name out of
# "Apple;Carbon;Networking" at run time) is a great deal of machinery to
# adopt on a guess.

project(CursorRigApp C)

set(RIG_APP_SOURCES
    ${CMAKE_CURRENT_SOURCE_DIR}/src/rig_app.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../contract/cursor_rig_logic.c
    ${CMAKE_CURRENT_SOURCE_DIR}/../contract/cursor_rig.h)
add_custom_target(CursorRigIntake_buildid ALL
    COMMAND python3 ${CMAKE_CURRENT_SOURCE_DIR}/../tools/gen_build_id.py
            ${CMAKE_CURRENT_BINARY_DIR}/app_build_stamp.c
            ${CMAKE_CURRENT_BINARY_DIR}/CursorRigIntake.buildid
            kRigAppBuildId ${RIG_APP_SOURCES}
    BYPRODUCTS ${CMAKE_CURRENT_BINARY_DIR}/app_build_stamp.c
    COMMENT "stamping the intake's build identity")

add_application(CursorRigIntake
    CREATOR "CRig"
    ${CMAKE_CURRENT_BINARY_DIR}/app_build_stamp.c
    src/rig_app.c
    ../contract/cursor_rig_logic.c)

target_include_directories(CursorRigIntake PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../contract)
target_compile_options(CursorRigIntake PRIVATE -Wall -Wextra -Os)
add_dependencies(CursorRigIntake CursorRigIntake_buildid)
