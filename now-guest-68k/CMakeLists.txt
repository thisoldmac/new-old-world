# NOW-68K: guest client for the PowerBook 180c (System 7.1, 4 MB, MacTCP-only
# - Open Transport cannot link on Retro68 68K, ASLM). Modeled on
# appe/CMakeLists.txt, but this app IS the user-facing window (APPL, not
# 'appe'; backgroundAndForeground in now-guest-68k.r, not onlyBackground), so it
# Finder-launches and double-clicks like a normal application.
#
#   cmake -S now-guest-68k -B build-68k -G Ninja \
#     -DCMAKE_TOOLCHAIN_FILE=$RETRO68_68K/m68k-apple-macos/cmake/retro68.toolchain.cmake
#   cmake --build build-68k
cmake_minimum_required(VERSION 3.13)
project(Now68kGuest C)

# 68K-only by design (target-runtime contract at the top of this file's
# companion docs): a PPC branch has nothing to build here, so fail loudly
# rather than silently produce a wrong-ISA or empty target.
if(NOT CMAKE_C_COMPILER MATCHES "m68k")
    message(FATAL_ERROR
        "now-guest-68k targets the PowerBook 180c (68030, System 7.1) only. "
        "Point CMAKE_TOOLCHAIN_FILE at the m68k Retro68 toolchain.")
endif()

add_application(now-guest-68k
    TYPE "APPL"
    CREATOR "NW68"
    src/main.c
    src/ui/window.c
    src/console/conwin.c
    # Not under src/: one implementation both guests compile, the way
    # contract/ carries the headers both guests include. See its own
    # header for why the console history in particular is out here.
    ../guest-shared/src/console_history.c
    src/commands/n68_cmdresult.c
    src/commands/n68_exec.c
    src/core/log.c
    src/core/frame.c
    src/core/json_scan.c
    src/core/numfmt.c
    src/core/hello.c
    src/core/ping.c
    src/console/n68_linesplit.c
    src/console/n68_console_ring.c
    src/core/n68_reader.c
    src/core/n68_crc32.c
    src/files/n68_putrx.c
    src/files/n68_putfile.c
    src/files/n68_puttx.c
    src/files/n68_filesrc.c
    src/files/n68_fileenum.c
    src/files/n68_filelist.c
    src/processes/n68_proclist.c
    src/connection/connfields.c
    src/connection/n68_devsettings.c
    src/connection/n68_devsettings_file.c
    src/core/net_mactcp.c
    src/core/wire68.c
    src/ui/health.c
    src/commands/commands68.c
    src/census/n68_vprobe.c
    src/core/screen68.c
    src/census/vprobe68.c
    src/screenshots/n68_shot.c
    src/screenshots/shot68.c
    src/screenshots/n68_shotwire.c
    src/screenshots/shotsrc68.c
    src/screenshots/n68_packbits.c
    src/screenshots/shotstage68.c
    src/processes/proc_quit_args.c
    src/processes/proc68.c
    now-guest-68k.r
)

# src/ is split by domain (core/, commands/, files/, ...), but the sources
# include their headers by BARE NAME - "frame.h", not "core/frame.h". Which
# domain a header is filed under is a decision about where a human looks for
# it, and re-filing one should not touch every file that includes it, so
# every domain directory goes on the include path.
#
# GLOB rather than a hand-kept list because the two must never disagree: a
# list that missed a new domain would fail as "no such file", pointing at the
# include rather than at this line. Configure-time is the right time - adding
# a directory is already a re-run of cmake.
file(GLOB NOW68K_SRC_DIRS LIST_DIRECTORIES true
     ${CMAKE_CURRENT_SOURCE_DIR}/src/*)
list(FILTER NOW68K_SRC_DIRS EXCLUDE REGEX "\\.[ch]$")

target_include_directories(now-guest-68k PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${NOW68K_SRC_DIRS}
    ${CMAKE_CURRENT_SOURCE_DIR}/../contract
    ${CMAKE_CURRENT_SOURCE_DIR}/../guest-shared/src)

# Retro68/CMake defaults to -O0 when no optimization level is set, which
# would make every later size/timing measurement on this milestone
# meaningless - set it explicitly rather than inheriting a default.
#
# The warning gate is not optional here. The pure-C units were developed on
# the host under -Wall -Wextra -Werror and one of their real bugs was caught
# by -Werror alone; moving those files in-tree without the same gate would
# silently drop it. It already has something to say about this shell.
target_compile_options(now-guest-68k PRIVATE -O2 -Wall -Wextra -Werror)

# vprobe68.c is the one file with inline assembly, and two of the three
# idioms it measures (fmove.d through the 68882) do not exist for the
# 68000 this application is otherwise built for - gas refuses the mnemonic
# outright. This raises the ASSEMBLER's architecture for that one file
# only; the compiler still emits 68000 code for it (there is no
# -mcpu=68030 in the compile options, deliberately), so nothing but the
# hand-written instructions depends on the 030. Those instructions are in
# turn gated at runtime on Gestalt reporting an FPU, because on System 7.1
# an F-line trap with no FPU and no emulator is a crash, not a slow path.
#
# The whole file rather than a fragment because gas's .arch/.cpu
# directives must precede the first instruction in a translation unit and
# so cannot be scoped inside an asm block - checked, not assumed.
set_source_files_properties(src/census/vprobe68.c PROPERTIES
    COMPILE_OPTIONS "-Wa,-mcpu=68030")

# 68K resolves everything from InterfaceLib traps (Event/Window/Menu/TextEdit/
# Dialog/AppleEvent Managers, File Manager via libc's stdio shim, Device
# Manager for net_mactcp.c's .IPP calls) - no extra link libraries, matching
# appe's m68k branch.
