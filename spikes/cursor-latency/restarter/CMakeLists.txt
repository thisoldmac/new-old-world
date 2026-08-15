cmake_minimum_required(VERSION 3.13)

# RigRestart - a 68K, NON-Carbon application, because the Shutdown
# Manager is "CarbonLib: not available" and this is the one thing in the
# rig that has to reach it. Built with the 68K toolchain.

project(RigRestart C ASM)

add_application(RigRestart
    CREATOR "CRgR"
    src/rig_restart.c
    src/rig_restart.S)

target_compile_options(RigRestart PRIVATE -mcpu=68000 -Wall -Wextra -Os)
