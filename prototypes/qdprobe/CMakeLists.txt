cmake_minimum_required(VERSION 3.13)

# QD Probe - the P3 spike (prototypes/qdprobe/README.md). A THROWAWAY
# 68K INIT, not a NOW component: its own name, creator and Gestalt
# selector, so that a fault here is a separate failure domain from the
# shipping extension in fact and not just in intent.
#
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=$NOW68K_TOOLCHAIN prototypes/qdprobe
#   cmake --build build
#
# Install QDProbe.bin into System Folder:Extensions on a DISPOSABLE clone
# and cold-boot. Recovery is a shift-boot, in place before the install.

project(QDProbe C ASM)

add_executable(QDProbe
    src/qdprobe.c
    src/qdprobe_gne.S)

# -mcpu=68000 for the whole 8.6-9.2.2 range, including 68K-emulated
# PowerPC - which is the configuration this spike is actually about.
target_compile_options(QDProbe PRIVATE -mcpu=68000 -Wall -Wextra -Werror -Os)
set_target_properties(QDProbe PROPERTIES
    OUTPUT_NAME QDProbe.flt
    LINK_FLAGS "-Wl,--mac-flat -Wl,-Map,QDProbe.map")

# Creator 'QDpr', not 'NOWx'. See the identity table in README.md.
add_custom_command(
    OUTPUT QDProbe.bin QDProbe.dsk
    COMMAND ${REZ} -I${REZ_INCLUDE_PATH}
                   ${CMAKE_CURRENT_SOURCE_DIR}/src/qdprobe.r
                   -o QDProbe.bin
                   --cc QDProbe.dsk
                   -t INIT -c QDpr
    DEPENDS QDProbe src/qdprobe.r)

add_custom_target(QDProbe_INIT ALL DEPENDS QDProbe.dsk)
