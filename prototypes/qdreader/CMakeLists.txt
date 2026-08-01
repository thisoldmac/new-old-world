cmake_minimum_required(VERSION 3.13)

# QD Reader - the reader half of the P3 spike (prototypes/qdreader/README.md).
# A THROWAWAY Carbon/PPC application, not a NOW component: its own name and
# its own creator, deleted when QD Probe is.
#
# Carbon/PPC on purpose. Armed at itself, this application's own drawing is
# the native PowerPC caller the probe exists to ask about, so the reader is
# the experiment rather than a report of one.
#
#   cmake -B build -DCMAKE_TOOLCHAIN_FILE=$NOW_PPC_TOOLCHAIN prototypes/qdreader
#   cmake --build build

project(QDReader C)

# Creator 'QDrd' - not 'QDpr' (the probe's), not 'NOWx'/'NOWs' (NOW's).
add_application(QDReader
    CREATOR "QDrd"
    src/main.c
)

target_compile_options(QDReader PRIVATE -Wall -Wextra -Werror -Os)
