# Derive two deterministic identities for the resident artifact inputs.
file(GLOB _sources
     "${SRC_DIR}/*.c" "${SRC_DIR}/*.h" "${SRC_DIR}/*.S" "${SRC_DIR}/*.r")
list(APPEND _sources "${CONTRACT}")
list(SORT _sources)
set(_manifest "")
foreach(_file IN LISTS _sources)
    file(SHA1 "${_file}" _hash)
    get_filename_component(_name "${_file}" NAME)
    string(APPEND _manifest "${_name} ${_hash}\n")
endforeach()
string(SHA1 _source_hash "${_manifest}")
string(SHA1 _build_hash "${_source_hash}:NWex:NWpt:1")

set(_defines "")
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
file(WRITE "${REZ_OUT}"
"/* Generated; raw source hash followed by resident build fingerprint. */
data 'NWid' (128, \"NOW Extension Build\") {
    $\"${_source_hash}${_build_hash}\"
};
")
