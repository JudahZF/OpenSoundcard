#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: build-macos.sh

Builds the OpenSoundcard macOS artifacts:
  - Rust release library for opensoundcard-core
  - generated C FFI header
  - CoreAudio HAL .driver bundle
  - manager app, if an Xcode project has been added

Environment overrides:
  OSC_BUILD_DIR   Output directory. Defaults to <repo>/target/macos.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
	usage
	exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUILD_ROOT="${OSC_BUILD_DIR:-$REPO_ROOT/target/macos}"
PLUGIN_SOURCE_DIR="$REPO_ROOT/platform/macos/CoreAudioPlugin"
HEADER_DIR="$REPO_ROOT/platform/macos/include"
RUST_STATIC_LIB="$REPO_ROOT/target/release/libopensoundcard_core.a"
BUNDLE_NAME="OpenSoundcard.driver"
BUNDLE_PATH="$BUILD_ROOT/$BUNDLE_NAME"
BUNDLE_CONTENTS="$BUNDLE_PATH/Contents"
BUNDLE_MACOS="$BUNDLE_CONTENTS/MacOS"
BUNDLE_EXECUTABLE="$BUNDLE_MACOS/OpenSoundcardAudioServerPlugIn"

require_command() {
	if ! command -v "$1" >/dev/null 2>&1; then
		echo "error: $1 is required. Run 'direnv allow' or use 'nix develop'." >&2
		exit 1
	fi
}

run_with_nix_dev_shell() {
	if [[ -z "${IN_NIX_SHELL:-}" &&
		-z "${OSC_NO_NIX_REEXEC:-}" &&
		-f "$REPO_ROOT/flake.nix" ]] &&
		command -v nix >/dev/null 2>&1; then
		(cd "$REPO_ROOT" && nix develop -c "$@")
		return 0
	fi

	"$@"
}

build_rust_release_library() {
	if ! command -v cargo >/dev/null 2>&1; then
		run_with_nix_dev_shell cargo build --release -p opensoundcard-core
		return 0
	fi

	run_with_nix_dev_shell cargo build --release -p opensoundcard-core
}

generate_ffi_header() {
	if command -v cbindgen >/dev/null 2>&1; then
		"$SCRIPT_DIR/generate-ffi-header.sh"
		return 0
	fi

	run_with_nix_dev_shell bash "$SCRIPT_DIR/generate-ffi-header.sh"
}

host_xcrun() {
	local xcrun_bin="${OSC_XCRUN:-/usr/bin/xcrun}"

	if [[ ! -x "$xcrun_bin" ]]; then
		xcrun_bin="$(command -v xcrun || true)"
	fi

	if [[ -z "$xcrun_bin" ]]; then
		echo "error: xcrun is required. Install Xcode or Xcode command-line tools." >&2
		exit 1
	fi

	env \
		-u CPATH \
		-u DEVELOPER_DIR \
		-u LIBRARY_PATH \
		-u NIX_CC \
		-u NIX_CFLAGS_COMPILE \
		-u NIX_ENFORCE_NO_NATIVE \
		-u NIX_LDFLAGS \
		-u SDKROOT \
		"$xcrun_bin" "$@"
}

build_coreaudio_bundle() {
	rm -rf "$BUNDLE_PATH"
	mkdir -p "$BUNDLE_MACOS"

	cp "$PLUGIN_SOURCE_DIR/Info.plist" "$BUNDLE_CONTENTS/Info.plist"

	host_xcrun clang \
		-std=c11 \
		-Wall \
		-Wextra \
		-Werror \
		-fPIC \
		-bundle \
		-I "$PLUGIN_SOURCE_DIR" \
		-I "$HEADER_DIR" \
		"$PLUGIN_SOURCE_DIR/OpenSoundcardAudioServerPlugIn.c" \
		"$PLUGIN_SOURCE_DIR/OpenSoundcardDevice.c" \
		"$RUST_STATIC_LIB" \
		-framework CoreAudio \
		-framework CoreFoundation \
		-o "$BUNDLE_EXECUTABLE"

	echo "Built CoreAudio HAL bundle: $BUNDLE_PATH"
}

build_manager_app_if_present() {
	local project
	project="$(command find "$REPO_ROOT/platform/macos" \
		-maxdepth 4 \
		-name "*.xcodeproj" \
		-print \
		-quit)"

	if [[ -z "$project" ]]; then
		echo "Skipping manager app build: no Xcode project found under platform/macos."
		return 0
	fi

	require_command xcodebuild
	echo "Building manager app from Xcode project: $project"
	xcodebuild \
		-project "$project" \
		-configuration Release \
		-derivedDataPath "$BUILD_ROOT/DerivedData" \
		build
}

cd "$REPO_ROOT"

echo "Building opensoundcard-core release library..."
build_rust_release_library

echo "Generating FFI header..."
generate_ffi_header

echo "Building CoreAudio HAL bundle..."
build_coreaudio_bundle

build_manager_app_if_present

cat <<EOF

macOS build complete.
Bundle: $BUNDLE_PATH
Install with: $SCRIPT_DIR/install-plugin.sh
EOF
