cmake_minimum_required(VERSION 3.13)
project(NowGuest C)

set(NOW_UPDATE_CHANNEL "development" CACHE STRING
    "Update manifest channel (development, candidate, or release)")
set_property(CACHE NOW_UPDATE_CHANNEL PROPERTY STRINGS
    development candidate release)
set(NOW_RELEASE_CANDIDATE "" CACHE STRING
    "Positive rc number when NOW_UPDATE_CHANNEL is candidate")
set(_update_candidate_args)
if(NOW_UPDATE_CHANNEL STREQUAL "candidate")
    if(NOT NOW_RELEASE_CANDIDATE MATCHES "^[1-9][0-9]*$")
        message(FATAL_ERROR
            "candidate update channel requires NOW_RELEASE_CANDIDATE=N")
    endif()
    list(APPEND _update_candidate_args
        --candidate-number ${NOW_RELEASE_CANDIDATE})
endif()

add_application(now-guest-ppc
    CREATOR "NOWo"
    src/main.c
    src/commands/cmd_help.c
    src/commands/cmd_line.c
    src/commands/commands.c
    src/commands/gestalt_json.c
    src/console/console_model.c
    src/console/console_reply.c
    src/console/console_module.c
    src/console/console_module_definition.c
    # Not under src/: one implementation both guests compile, the way
    # contract/ carries the headers both guests include. See its own
    # header for why the console history in particular is out here.
    ../now-guest-shared/src/console_history.c
    ../now-guest-shared/src/macbinary_lengths.c
    src/screenshots/capture.c
    src/files/fileshare.c
    src/files/files_module_definition.c
    src/files/files_capacity.c
    src/core/pump.c
    src/core/db_hilite.c
    src/core/build_stamp.c
    src/core/agent_access.c
    src/core/product_features.generated.c
    src/core/product_feature_policy.c
    src/screenshots/screenshot.c
    src/census/vprobe.c
    src/files/catsearch.c
    src/software/software.c
    src/software/sw_vers_parse.c
    src/software/software_layout.c
    src/software/software_module.c
    src/software/software_module_definition.c
    src/screenshots/pixels.c
    src/screenshots/screenshots_module.c
    src/screenshots/screenshots_module_definition.c
    src/census/census_module.c
    src/census/census_module_definition.c
    src/census/census_probes.c
    src/census/census_trap.c
    src/logs/logs_module.c
    src/mcp/mcp_layout.c
    src/mcp/mcp_module.c
    src/preferences/preferences_module.c
    src/diagnostics/diag_layout.c
    src/diagnostics/diagnostics_module.c
    src/network/net_facts.c
    src/network/net_layout.c
    src/network/net_probe.c
    src/network/network_module.c
    src/network/network_module_definition.c
    src/chat/chat_layout.c
    src/chat/chat_model.c
    src/chat/chat_module.c
    src/cloud/cloud_card_cache.c
    src/cloud/cloud_filter.c
    src/cloud/cloud_layout.c
    src/cloud/cloud_model.c
    src/cloud/cloud_module.c
    src/cloud/cloud_module_definition.c
    src/cloud/cloud_nav.c
    src/cloud/cloud_preview.c
    src/cloud/cloud_photo_size.c
    src/cloud/cloud_preview_well.c
    src/cloud/cloud_drive_view.c
    src/cloud/cloud_list_view.c
    src/cloud/cloud_photos_view.c
    src/cloud/cloud_contacts_card.c
    src/cloud/cloud_contacts_view.c
    src/mirror/mirror_anchor.c
    src/mirror/mirror_layout.c
    src/mirror/mirror_log.c
    src/mirror/mirror_policy.c
    src/mirror/mirror_json.c
    src/mirror/mirror_probe.c
    src/mirror/mirror_module.c
    src/development/development_contract.c
    src/development/development_build.c
    src/development/development_project.c
    src/development/development_candidate.c
    src/development/development_sha256.c
    src/development/development_open.c
    src/development/development_runtime.c
    src/development/development_command.c
    src/development/development_toolchain_mac.c
    src/development/development_layout.c
    src/development/development_module.c
    src/web/web_model.c
    src/web/web_port_dialog.c
    src/web/web_module.c
    src/mirror/mirror_show.c
    src/census/census_decode.c
    src/census/census_report.c
    src/files/files_module.c
    src/files/files_browser_view.c
    src/files/files_path_label.c
    src/files/files_share_view.c
    src/files/files_pull.c
    src/workshop/confirm.c
    src/core/ot_carbon.c
    src/core/json.c
    src/core/screen_bounds.c
    src/core/loopstat.c
    src/core/wire_sleep.c
    src/core/wirestat_cmd.c
    src/core/nowlog.c
    ../now-guest-shared/src/log_retention.c
    ../now-guest-shared/src/log_retention_classic.c
    src/core/wire.c
    src/core/prefs.c
    src/connection/conn_fields.c
    src/connection/conn_edit_dialog.c
    src/connection/connection_module.c
    src/update/sha256.c
    src/update/update_model.c
    src/update/update_install.c
    src/update/update_status.c
    src/peek/peek.c
    src/peek/peek_lease.c
    src/peek/peek_validate.c
    src/peek/peek_oracle.c
    src/peek/event_read.c
    src/peek/transition_coordinator.c
    src/peek/arm_target.c
    src/peek/anchor_acquire.c
    src/peek/anchor_cycle.c
    src/peek/anchor_acquire_logic.c
    src/peek/transitions_logic.c
    src/peek/transitions_cmd.c
    src/peek/peek_read.c
    src/peek/semantic_client.c
    src/peek/semantic_policy.c
    ../now-guest-shared/src/now_semantic_guard.c
    src/processes/proc_actions.c
    src/processes/proc_hide_args.c
    src/processes/proc_quit_args.c
    src/processes/proc_roster.c
    src/processes/processes_layout.c
    src/processes/processes_module.c
    src/processes/processes_module_definition.c
    src/workshop/workshop_construct.c
    src/workshop/workshop_registry.c
    src/workshop/workshop_layout.c
    src/workshop/workshop_sidebar.c
    src/workshop/workshop_window.c
    src/scene/scene_build.c
    src/scene/scene_digest.c
    src/scene/scene_json.c
    src/scene/scene_phase.c
    src/scene/scene_collect.c
    src/scene/scene_theme.c
    src/scene/front_order.c
    src/scene/scene_self.c
    src/workshop/control_kind.c
    src/scene/scene_walk.c
    src/scene/control_cdef.c
    src/scene/cdef_resolver.c
    src/scene/dialog_text.c
    # The foreign-memory walk, ported from this project's own prototype
    # (timbottu/mirror). Pure parsers plus one Toolbox binding; see
    # src/axwalk/axwalk.h for why its constants are evidence.
    src/axwalk/axwalk.c
    src/axwalk/axmenu.c
    src/axwalk/axtext.c
    src/axwalk/axresolve.c
    src/axwalk/axbinding.c
    src/axwalk/axprocess.c
    # The reference layer over that walk: minting the opaque references
    # every act verb addresses, and resolving one back to a live element
    # or refusing with the reason. The deciding half (obsref.c,
    # obsresolve.c) is Toolbox-free and natively tested; observe.c only
    # obtains. See src/observe/obsref.h on why a reference cannot be
    # forged, and obsresolve.h on why staleness is never repaired.
    src/observe/obsref.c
    src/observe/obsresolve.c
    # The seam the SCENE walk mints through - the second walk over this
    # machine, and deliberately NOT a second registry (see obsmint.h).
    src/observe/obsmint.c
    src/observe/observe.c

    # P4, the act plane's application half. act_args.c is Toolbox-free
    # and natively tested; act_client.c is the thin Toolbox layer;
    # act_cmds.c is the five act commands - the sixth, `elements`, is
    # served by the reference layer above, because minting is one
    # mechanism and act_ref.c was a second one. now_act_guard.c is SHARED
    # with the 68K extension - one file, both sides of the seam, which is
    # what lets the host cc test the guard that runs inside other
    # people's applications.
    src/act/act_args.c
    src/act/act_settlement.c
    src/act/act_client.c
    src/act/act_cmds.c
    src/act/ctlact_line.c
    src/act/act_menu_probe.c
    src/act/act_menu_identity.c
    ../now-guest-shared/src/now_act_guard.c
    # The one-act-at-a-time latch. Shared and natively tested for the
    # same reason the guard is: it is the thing standing in for a
    # protection that was deliberately spent on 2026-08-06, so it must be
    # checkable somewhere a cross-compiler is not needed.
    ../now-guest-shared/src/now_act_inflight.c

    # Two verbs about the machine's own state, folded in from the parked
    # upstream project (docs/mirror-foldin-inventory.md, wave 3):
    # `activate`, which fronts a process by the identity an observation
    # minted rather than by name, and `actselftest`, which is the first
    # caller the act plane's ABI selftest has ever had. Same split as the
    # act plane itself - the parse and both verdicts are Toolbox-free and
    # natively tested; the two .c files that include Carbon decide
    # nothing.
    src/machine/mach_activate_args.c
    src/machine/mach_selftest_report.c
    src/machine/mach_reply.c
    src/machine/mach_activate.c
    src/machine/mach_selftest.c
    # The desktop's own account of itself, via the Appearance Manager's
    # theme collection. Same split again: desktop_report.c is Toolbox-free
    # and natively tested, desktop_theme.c holds every Toolbox call and
    # decides nothing the report cannot show.
    src/machine/desktop_report.c
    src/machine/desktop_theme.c
    # The input plane: mouseloc (a read, and the instrument the act plane
    # is measured with), script (OSADoScript) and aesend (four core Apple
    # Events, a closed vocabulary rather than a class/id pipe).
    # input_args.c is Toolbox-free and natively tested - it holds the
    # timeout clamp, the CR conversion classic AppleScript needs, the
    # `entire contents` refusal, and the serials aesend will not address;
    # input_cmds.c is the thin Toolbox layer over it.
    src/input/input_args.c
    src/input/input_cmds.c
    resources/app.r
    # The application icon family, generated from the artwork by
    # assets/icons/classic/rez.py and shared with any other target that
    # wants it. Referenced where it is generated rather than copied in: a
    # copy is a second definition of a file whose own header says not to
    # hand-edit it, and the two would drift the first time the art moved.
    ../assets/icons/classic/now-icons.r
)

# src/ is split by domain (core/, commands/, workshop/, ...), but the
# sources include their headers by BARE NAME - "json.h", not "core/json.h".
# Which domain a header is filed under is a decision about where a human
# looks for it, and re-filing one should not touch every file that includes
# it, so every domain directory goes on the include path.
#
# GLOB rather than a hand-kept list because the two must never disagree: a
# list that missed a new domain would fail as "no such file", pointing at the
# include rather than at this line. Configure-time is the right time - adding
# a directory is already a re-run of cmake.
file(GLOB NOW_GUEST_SRC_DIRS LIST_DIRECTORIES true
     ${CMAKE_CURRENT_SOURCE_DIR}/src/*)
list(FILTER NOW_GUEST_SRC_DIRS EXCLUDE REGEX "\\.[ch]$")

# contract/ carries the in-memory table header shared with the 68K
# extension build - the wire contract's sibling.
target_include_directories(now-guest-ppc PRIVATE
    src ${NOW_GUEST_SRC_DIRS} ../contract ../now-guest-shared/src)
target_compile_options(now-guest-ppc PRIVATE
    -Wall
    -Wextra
    -Werror
)

# Include the build output directory so build_stamp.c can find build_stamp_gen.h
target_include_directories(now-guest-ppc PRIVATE ${CMAKE_CURRENT_BINARY_DIR})


# The probe times tight read loops; at -O0 loop overhead pollutes the
# bandwidth numbers.
set_source_files_properties(src/census/vprobe.c PROPERTIES COMPILE_OPTIONS "-O2")

# --- ShowHideProcess: one import library the default link cannot see -------
#
# `hide` needs ShowHideProcess and IsProcessVisible (Process Manager,
# CarbonLib 1.5 and later). Our floor is CarbonLib 1.6, so they exist on
# every machine we target - and this TOOLCHAIN cannot reach them, for two
# separate reasons that have each closed this route once:
#
#   1. The headers on the include path are Universal Interfaces 3.4. Both
#      calls arrived in 3.4.1. proc_actions.c declares them itself, with
#      the 3.4.1 text and the selector, rather than waiting for a header.
#   2. Retro68 ships TWO CarbonLib import libraries and they differ:
#
#        toolchain/multiversal/libppc/libCarbonLib.a   3.4.1-derived, HAS them
#        toolchain/universal/libppc/libCarbonLib.a     locally generated, does not
#        toolchain/powerpc-apple-macos/lib/libCarbonLib.a  -> symlink to `universal`
#
#      The default `-lCarbonLib` therefore resolves against the archive
#      WITHOUT the symbols, and the first check of this route reported "the
#      Process Manager's visibility call is absent from the toolchain under
#      any spelling" from exactly that archive.
#
# So the 3.4.1 archive is named explicitly, by absolute path, and nothing
# else about the link changes. Deliberately NOT a `-L` onto that directory:
# a search path applies to every `-l` on the line (-lgcc, -lc,
# -lretrocrt-carbon), and shadowing one of those by accident is a far worse
# failure than the one being fixed. Archive members load on demand, so the
# 3.4.1 archive answers first and the default one supplies whatever it does
# not have - the resulting PEF carries exactly two CarbonLib import entries,
# one strong and one weak, the same as before.
#
# ABSENT, THE BUILD STILL SUCCEEDS AND THE VERB REFUSES BY NAME. A
# contributor whose Retro68 has only the locally generated archive is not
# failing a gate; they get a guest that says "this Mac's CarbonLib does not
# export ShowHideProcess" instead of one that will not link. The runtime
# guard in proc_actions.c is the second, independent gate: the import is
# WEAK, so a CarbonLib older than 1.5 resolves it to zero at load and the
# same refusal is printed by a binary that built with the symbol present.
#
# The string search is not the proof - the LINK is. If it hits on an archive
# that does not really define the symbols, the link fails naming them, which
# is loud. It only decides which of the two shapes to compile.
set(NOW_CARBONLIB_341 "${RETRO68_ROOT}/multiversal/libppc/libCarbonLib.a"
    CACHE FILEPATH
    "CarbonLib import library derived from Universal Interfaces 3.4.1")
set(_now_have_showhide 0)
if(EXISTS "${NOW_CARBONLIB_341}")
    file(STRINGS "${NOW_CARBONLIB_341}" _now_shp LIMIT_COUNT 1
         REGEX "ShowHideProcess")
    file(STRINGS "${NOW_CARBONLIB_341}" _now_ipv LIMIT_COUNT 1
         REGEX "IsProcessVisible")
    if(_now_shp AND _now_ipv)
        set(_now_have_showhide 1)
    endif()
endif()

if(_now_have_showhide)
    target_link_libraries(now-guest-ppc PRIVATE "${NOW_CARBONLIB_341}")
    target_compile_definitions(now-guest-ppc PRIVATE
        NOW_HAVE_SHOWHIDEPROCESS=1)
    message(STATUS "hide: linking ShowHideProcess from ${NOW_CARBONLIB_341}")
else()
    target_compile_definitions(now-guest-ppc PRIVATE
        NOW_HAVE_SHOWHIDEPROCESS=0)
    message(STATUS
        "hide: no CarbonLib import library with ShowHideProcess at "
        "${NOW_CARBONLIB_341} - the `hide` verb will refuse by name. "
        "Point -DNOW_CARBONLIB_341=... at a 3.4.1-derived libCarbonLib.a "
        "(Retro68 ships one in ImportLibraries/) to build it in.")
endif()

# Generate the build stamp on every build. The buildstamp.cmake script hashes
# the full declared application build surface plus the toolchain profile. The
# header is rewritten only when the identity changes, so an unchanged tree does
# not force a universal recompile. See cmake/buildstamp.cmake for rationale.
set(_buildstamp_header ${CMAKE_CURRENT_BINARY_DIR}/build_stamp_gen.h)
add_custom_target(generate_buildstamp ALL
    COMMAND ${CMAKE_COMMAND}
            -DROOT=${CMAKE_CURRENT_SOURCE_DIR}/..
            -DTOOLCHAIN_ID=${CMAKE_C_COMPILER_ID}-${CMAKE_C_COMPILER_VERSION}-${CMAKE_SYSTEM_NAME}-${CMAKE_SYSTEM_PROCESSOR}
            -DOUT=${_buildstamp_header}
            -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/buildstamp.cmake
    BYPRODUCTS ${_buildstamp_header}
    VERBATIM)
add_dependencies(now-guest-ppc generate_buildstamp)

# ...and rebuild the ONE file that bakes the hash in, whenever that header
# changes. Without this the stamp UNDER-REPORTS: the header regenerates
# with the new hash, every other object rebuilds from the changed source,
# and build_stamp.o alone keeps the previous string - so the binary
# carries the new code and reports the old identity.
#
# Measured 2026-08-02: a scene fix was staged and tested, the guest
# announced the PREVIOUS stamp, and the obvious reading was "the change
# did not land" - which would have discarded a real measurement and sent
# somebody to re-fix code that was already running. AGENTS.md's rule
# ("check the build stamp before believing a test result") assumes the
# stamp errs on the side of being early; this made it err the other way,
# which is worse, because a stale-looking stamp invites you to disbelieve
# a true result.
set_source_files_properties(src/core/build_stamp.c
    PROPERTIES OBJECT_DEPENDS ${_buildstamp_header})

# The canonical deploy artifact carries the product's real name, spaces
# and all: "New Old World.bin", to match "New Old World.app" on the host.
# A classic HFS name allows the spaces; a CMake target name does not, and
# Retro68 names the MacBinary after the target - so the name is stamped
# into a copy of the .bin here instead. This is not cosmetic: Rumpus
# decodes the .bin by its INTERNAL name, and prefs.c keys the canonical
# preferences (and the real host, not the 10.0.2.2 emulator gateway) off
# that process name. now-guest-ppc.bin stays for dev / side-by-side testing;
# "New Old World.bin" is the one that goes to metal and lands on main.

find_program(PYTHON3_EXECUTABLE NAMES python3 python)
if(PYTHON3_EXECUTABLE)
    add_custom_command(
        OUTPUT "New Old World.bin"
        COMMAND ${PYTHON3_EXECUTABLE}
                "${CMAKE_CURRENT_SOURCE_DIR}/tools/name_macbinary.py"
                "now-guest-ppc.bin" "New Old World.bin" "New Old World"
        DEPENDS now-guest-ppc.bin
                "${CMAKE_CURRENT_SOURCE_DIR}/tools/name_macbinary.py"
        COMMENT "Stamping canonical MacBinary: New Old World.bin"
        VERBATIM)
    add_custom_target(now-guest-ppc-canonical ALL DEPENDS "New Old World.bin")
    add_custom_command(
        OUTPUT "New Old World.bin.now-update.json"
        COMMAND ${PYTHON3_EXECUTABLE}
                "${CMAKE_CURRENT_SOURCE_DIR}/../tools/write-update-manifest.py"
                --artifact "New Old World.bin"
                --component application
                --version-header
                    "${CMAKE_CURRENT_SOURCE_DIR}/../contract/product_version.h"
                --version-major NOW_PRODUCT_VERSION_MAJOR
                --version-minor NOW_PRODUCT_VERSION_MINOR
                --version-patch NOW_PRODUCT_VERSION_PATCH
                --lifecycle-define NOW_PRODUCT_LIFECYCLE
                --lifecycle-number-define NOW_PRODUCT_LIFECYCLE_NUMBER
                --identity-header "${_buildstamp_header}"
                --identity-define NOW_BUILD_ID
                --channel ${NOW_UPDATE_CHANNEL}
                ${_update_candidate_args}
                --repo-root "${CMAKE_CURRENT_SOURCE_DIR}/.."
        DEPENDS "New Old World.bin" ${_buildstamp_header}
                "${CMAKE_CURRENT_SOURCE_DIR}/../tools/write-update-manifest.py"
        COMMENT "Writing canonical update identity"
        VERBATIM)
    add_custom_target(now-guest-ppc-update-manifest ALL
        DEPENDS "New Old World.bin.now-update.json")
else()
    message(WARNING
        "python3 not found: skipping the canonical 'New Old World.bin' "
        "stamp; deploy now-guest-ppc.bin renamed by hand (see AGENTS.md).")
endif()

# P3's READER - the content plane's application half (src/content/).
#
# Appended with target_sources rather than added to the add_application
# list above, because that list is held by another lane while this is
# written and an append cannot collide with an edit. The include path
# needs no change: NOW_GUEST_SRC_DIRS globs every directory under src/,
# which is what makes a new domain cost one commit instead of two.
#
# qdtrace_read.c and qdtrace_json.c are Toolbox-free and are run by
# scripts/test-native against rings the real writer builds;
# qdtrace_cmd.c is the only Toolbox in the plane's reader.
target_sources(now-guest-ppc PRIVATE
    src/content/qdtrace_read.c
    src/content/qdtrace_json.c
    src/content/qdtrace_cmd.c
    src/content/qdtrace_target.c)
