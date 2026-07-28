# NOW-68K: guest client for the PowerBook 180c (System 7.1, 4 MB, MacTCP-only
# - Open Transport cannot link on Retro68 68K, ASLM). Modeled on
# appe/CMakeLists.txt, but this app IS the user-facing window (APPL, not
# 'appe'; backgroundAndForeground in guest68k.r, not onlyBackground), so it
# Finder-launches and double-clicks like a normal application.
#
#   cmake -S guest68k -B build-68k -G Ninja \
#     -DCMAKE_TOOLCHAIN_FILE=$RETRO68_68K/m68k-apple-macos/cmake/retro68.toolchain.cmake
#   cmake --build build-68k
cmake_minimum_required(VERSION 3.13)
project(Now68kGuest C)

# 68K-only by design (target-runtime contract at the top of this file's
# companion docs): a PPC branch has nothing to build here, so fail loudly
# rather than silently produce a wrong-ISA or empty target.
if(NOT CMAKE_C_COMPILER MATCHES "m68k")
    message(FATAL_ERROR
        "guest68k targets the PowerBook 180c (68030, System 7.1) only. "
        "Point CMAKE_TOOLCHAIN_FILE at the m68k Retro68 toolchain.")
endif()

add_application(now68k-guest
    TYPE "APPL"
    CREATOR "NW68"
    src/main.c
    src/window.c
    src/conwin.c
    src/n68_history.c
    src/n68_cmdresult.c
    src/n68_exec.c
    src/log.c
    src/frame.c
    src/json_scan.c
    src/numfmt.c
    src/hello.c
    src/ping.c
    src/n68_linesplit.c
    src/n68_console_ring.c
    src/n68_reader.c
    src/n68_crc32.c
    src/n68_putrx.c
    src/n68_putfile.c
    src/n68_puttx.c
    src/n68_filesrc.c
    src/n68_fileenum.c
    src/n68_filelist.c
    src/n68_proclist.c
    src/connfields.c
    src/n68_devsettings.c
    src/n68_devsettings_file.c
    src/net_mactcp.c
    src/wire68.c
    src/health.c
    src/commands68.c
    src/n68_vprobe.c
    src/screen68.c
    src/vprobe68.c
    src/n68_shot.c
    src/shot68.c
    src/n68_shotwire.c
    src/shotsrc68.c
    src/n68_packbits.c
    src/shotstage68.c
    src/proc_quit_args.c
    src/proc68.c
    guest68k.r
)

target_include_directories(now68k-guest PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/../contract)

# Retro68/CMake defaults to -O0 when no optimization level is set, which
# would make every later size/timing measurement on this milestone
# meaningless - set it explicitly rather than inheriting a default.
#
# The warning gate is not optional here. The pure-C units were developed on
# the host under -Wall -Wextra -Werror and one of their real bugs was caught
# by -Werror alone; moving those files in-tree without the same gate would
# silently drop it. It already has something to say about this shell.
target_compile_options(now68k-guest PRIVATE -O2 -Wall -Wextra -Werror)

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
set_source_files_properties(src/vprobe68.c PROPERTIES
    COMPILE_OPTIONS "-Wa,-mcpu=68030")

# 68K resolves everything from InterfaceLib traps (Event/Window/Menu/TextEdit/
# Dialog/AppleEvent Managers, File Manager via libc's stdio shim, Device
# Manager for net_mactcp.c's .IPP calls) - no extra link libraries, matching
# appe's m68k branch.
