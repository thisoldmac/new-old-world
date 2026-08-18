# The build entry point. Every target compiles into build/, which is
# gitignored and per-checkout - a worktree brings its own, so two
# checkouts never share a CMake cache (the shared-drawer failure that
# reads like a broken checkout).
#
#     make            # everything this machine has toolchains for
#     make host       # the macOS app        -> build/host/New Old World.app
#     make ppc        # the PowerPC guest    -> build/ppc/New Old World.bin
#     make 68k        # the 68K guest        -> build/68k/
#     make ext        # the NOW Extension    -> build/ext/NOW Extension.bin
#     make guests     # ppc + 68k + ext
#     make clean
#
# Configuration comes from .env (cp .env.example .env); an explicit
# environment variable still wins over the file. A guest target that
# lacks its toolchain stops and names the missing key rather than
# guessing. This file owns the raw build invocations; scripts/ wraps
# them for gates and rigs.

BUILD := build

# Key lookup, in order: real environment, ./.env, ./.env.lab, then the
# main worktree's copies - a worktree is the same desk and the same
# Retro68 install, not a stranger (see scripts/build-guests for the
# afternoon that rule cost).
MAIN_WT := $(patsubst %/.git,%,$(shell git rev-parse --path-format=absolute --git-common-dir 2>/dev/null))
envfile = $(shell for f in .env .env.lab "$(MAIN_WT)/.env" "$(MAIN_WT)/.env.lab"; do \
    v=$$(sed -n 's/^$(1)=//p' "$$f" 2>/dev/null | head -1); \
    if [ -n "$$v" ]; then printf '%s\n' "$$v"; break; fi; done)

NOW_PPC_TOOLCHAIN ?= $(call envfile,NOW_PPC_TOOLCHAIN)
NOW68K_TOOLCHAIN ?= $(call envfile,NOW68K_TOOLCHAIN)
NOW_UPDATE_CHANNEL ?= $(or $(call envfile,NOW_UPDATE_CHANNEL),development)

# require-toolchain <key> <value>: refuse with the key named, the repo
# convention for desk configuration (docs/lab-setup.md).
define require-toolchain
	@if [ -z "$(2)" ]; then \
	    echo "error: $(1) is not set - cp .env.example .env and fill it in" >&2; \
	    echo "       (docs/lab-setup.md > Toolchains)" >&2; exit 64; fi
	@if [ ! -f "$(2)" ]; then \
	    echo "error: $(1)=$(2) does not exist" >&2; exit 64; fi
endef

# cmake-guest <source-dir> <build-subdir> <toolchain>
define cmake-guest
	cmake -S $(1) -B $(BUILD)/$(2) -G Ninja \
	    -DCMAKE_TOOLCHAIN_FILE="$(3)" \
	    -DNOW_UPDATE_CHANNEL=$(NOW_UPDATE_CHANNEL)
	cmake --build $(BUILD)/$(2)
endef

.PHONY: all guests ppc 68k ext host clean

all: guests host

guests: ppc 68k ext

# The PowerPC Carbon guest. The build stamp is touched first because
# CMake otherwise dates it from the previous build's end, and a stamp
# that errs late invites disbelieving a true test result (AGENTS.md).
ppc:
	$(call require-toolchain,NOW_PPC_TOOLCHAIN,$(NOW_PPC_TOOLCHAIN))
	@touch now-guest-ppc/src/core/build_stamp.c
	$(call cmake-guest,now-guest-ppc,ppc,$(NOW_PPC_TOOLCHAIN))
	@if [ ! -f "$(BUILD)/ppc/New Old World.bin" ]; then \
	    echo "error: build succeeded but 'New Old World.bin' was not stamped" >&2; \
	    echo "       (python3 missing?) - the canonical name gates preferences" >&2; \
	    echo "       and mirror arming, so this build cannot go to a machine" >&2; \
	    exit 70; fi
	@echo "-> $(BUILD)/ppc/New Old World.bin"

68k:
	$(call require-toolchain,NOW68K_TOOLCHAIN,$(NOW68K_TOOLCHAIN))
	$(call cmake-guest,now-guest-68k,68k,$(NOW68K_TOOLCHAIN))

# The NOW Extension is a 68K INIT even on a PowerPC machine - a property
# of classic Mac OS, not a choice - so it uses the 68K toolchain.
# Compiling it is NOT baking it: the staged image a run clones only
# changes through scripts/bake-ext-image.
ext:
	$(call require-toolchain,NOW68K_TOOLCHAIN,$(NOW68K_TOOLCHAIN))
	$(call cmake-guest,ext,ext,$(NOW68K_TOOLCHAIN))
	@echo "-> $(BUILD)/ext/NOW Extension.bin"

# The macOS app a person launches, ad-hoc signed so it runs on this
# machine (arm64 refuses unsigned binaries outright). Identity values
# come from tools/host-build-identity, never from configuration: Local
# Network privacy is attached to the bundle identifier, and a fresh one
# mints a fresh macOS identity. Team-signed and release builds stay in
# scripts/build-host-app and scripts/release-dmg.
host:
	xcodebuild \
	    -project now-host/NewOldWorld.xcodeproj \
	    -scheme "New Old World" \
	    -configuration Release \
	    -derivedDataPath $(abspath $(BUILD))/host/xcode-derived \
	    CONFIGURATION_BUILD_DIR=$(abspath $(BUILD))/host \
	    PRODUCT_BUNDLE_IDENTIFIER=$$(tools/host-build-identity canonical bundle-id) \
	    NOW_PRODUCT_NAME="$$(tools/host-build-identity canonical display-name)" \
	    NOW_DISPLAY_NAME="$$(tools/host-build-identity canonical display-name)" \
	    CODE_SIGNING_ALLOWED=NO \
	    build
	codesign --force --sign - "$(BUILD)/host/New Old World.app"
	@echo "-> $(BUILD)/host/New Old World.app"

clean:
	rm -rf $(BUILD)
