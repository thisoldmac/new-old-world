# Deterministic identities for the resident's complete declared build surface.
file(GLOB_RECURSE _sources
     "${ROOT}/ext/src/*.c"
     "${ROOT}/ext/src/*.h"
     "${ROOT}/ext/src/*.S"
     "${ROOT}/ext/src/*.r")
list(APPEND _sources
     "${ROOT}/ext/CMakeLists.txt"
     "${ROOT}/ext/cmake/build_identity.cmake"
     "${ROOT}/now-guest-shared/src/now_act_guard.c"
     "${ROOT}/now-guest-shared/src/now_act_guard.h"
     "${ROOT}/now-guest-shared/src/now_drag_logic.c"
     "${ROOT}/now-guest-shared/src/now_drag_logic.h"
     "${ROOT}/now-guest-shared/src/now_cursor_logic.c"
     "${ROOT}/now-guest-shared/src/now_cursor_logic.h"
     "${ROOT}/now-guest-shared/src/now_semantic_guard.c"
     "${ROOT}/now-guest-shared/src/now_semantic_guard.h"
     "${ROOT}/contract/content_table.h"
     "${ROOT}/contract/event_tail.h"
     "${ROOT}/contract/peek_table.h"
     "${ROOT}/contract/resident_version.h"
     "${ROOT}/contract/wire_limits.h")
list(REMOVE_DUPLICATES _sources)
list(SORT _sources)

set(_manifest "schema=now-component-build-v2\ncomponent=extension-source\n")
foreach(_file IN LISTS _sources)
    if(IS_DIRECTORY "${_file}")
        continue()
    endif()
    file(RELATIVE_PATH _path "${ROOT}" "${_file}")
    file(SHA256 "${_file}" _hash)
    string(APPEND _manifest "${_path}\t${_hash}\n")
endforeach()
string(SHA256 _source_hash "${_manifest}")
string(SHA256 _build_hash
       "schema=now-component-build-v2\ncomponent=extension\nsource=${_source_hash}\ntoolchain=${TOOLCHAIN_ID}\nresource=NWex:NWpt:1\n")

set(_defines "#define NOW_EXT_BUILD_ID \"${_build_hash}\"\n")
# The resident table is a fixed 160-bit ABI. Keep its layout stable by using
# the first 160 bits of the full update build identity; the sidecar carries all
# 256 bits and the artifact SHA-256 binds the exact MacBinary.
foreach(_kind SOURCE_MANIFEST BUILD_FINGERPRINT)
    if(_kind STREQUAL "SOURCE_MANIFEST")
        set(_value "${_source_hash}")
    else()
        set(_value "${_build_hash}")
    endif()
    foreach(_index RANGE 0 4)
        math(EXPR _start "${_index} * 8")
        string(SUBSTRING "${_value}" ${_start} 8 _word)
        string(APPEND _defines
            "#define NOW_EXT_${_kind}_${_index} 0x${_word}UL\n")
    endforeach()
endforeach()

file(WRITE "${HEADER}"
"/* Generated; do not commit. */
#ifndef NOW_EXT_BUILD_IDENTITY_H
#define NOW_EXT_BUILD_IDENTITY_H
${_defines}#endif
")
string(SUBSTRING "${_source_hash}" 0 40 _source_abi)
string(SUBSTRING "${_build_hash}" 0 40 _build_abi)
file(WRITE "${REZ_OUT}"
"/* Generated; first 160 bits of source and resident build identities. */
data 'NWid' (128, \"NOW Extension Build\") {
    $\"${_source_abi}${_build_abi}\"
};
")
