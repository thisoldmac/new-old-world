cmake_minimum_required(VERSION 3.13)

# CursorRig Starver - the load generator. PowerPC Carbon, same
# toolchain as the intake; see app/CMakeLists.txt for the invocation.

project(CursorRigStarver C)

add_application(CursorRigStarver
    CREATOR "CRgL"
    src/rig_starver.c)

target_include_directories(CursorRigStarver PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/../contract)
target_compile_options(CursorRigStarver PRIVATE -Wall -Wextra -Os)
