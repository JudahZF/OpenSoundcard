#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: install-plugin.sh [--dry-run] [--system]

Installs the built OpenSoundcard CoreAudio HAL driver.

Defaults to the current user's HAL plug-in directory:
  ~/Library/Audio/Plug-Ins/HAL

Options:
  --dry-run   Print actions without copying files.
  --system    Install to /Library/Audio/Plug-Ins/HAL. This usually needs sudo.

Environment overrides:
  OSC_BUILD_DIR   Build directory containing OpenSoundcard.driver.
  OSC_HAL_DIR     HAL plug-in install directory.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BUNDLE_NAME="OpenSoundcard.driver"
BUILD_ROOT="${OSC_BUILD_DIR:-$REPO_ROOT/target/macos}"
SOURCE_BUNDLE="$BUILD_ROOT/$BUNDLE_NAME"
INSTALL_DIR="${OSC_HAL_DIR:-$HOME/Library/Audio/Plug-Ins/HAL}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
		;;
	--system)
		INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "error: unknown argument: $1" >&2
		usage >&2
		exit 1
		;;
	esac
	shift
done

DEST_BUNDLE="$INSTALL_DIR/$BUNDLE_NAME"
TEMP_BUNDLE="$INSTALL_DIR/.$BUNDLE_NAME.tmp"

run() {
	if [[ "$DRY_RUN" -eq 1 ]]; then
		printf 'dry-run:'
		printf ' %q' "$@"
		printf '\n'
		return 0
	fi

	"$@"
}

run_with_optional_sudo() {
	if [[ "$DRY_RUN" -eq 1 ]]; then
		run "$@"
		return 0
	fi

	if [[ "$INSTALL_DIR" != /Library/* || (-d "$INSTALL_DIR" && -w "$INSTALL_DIR") ]]; then
		"$@"
		return 0
	fi

	echo "Using sudo because $INSTALL_DIR is not writable by the current user."
	sudo "$@"
}

if [[ ! -d "$SOURCE_BUNDLE" ]]; then
	echo "error: built bundle not found: $SOURCE_BUNDLE" >&2
	echo "Run: $SCRIPT_DIR/build-macos.sh" >&2
	exit 1
fi

if [[ "$INSTALL_DIR" == /Library/* ]]; then
	echo "Installing to the system HAL directory. macOS usually requires sudo here."
fi

run_with_optional_sudo mkdir -p "$INSTALL_DIR"
run_with_optional_sudo rm -rf "$TEMP_BUNDLE"
run_with_optional_sudo cp -R "$SOURCE_BUNDLE" "$TEMP_BUNDLE"
run_with_optional_sudo rm -rf "$DEST_BUNDLE"
run_with_optional_sudo mv "$TEMP_BUNDLE" "$DEST_BUNDLE"

if [[ "$DRY_RUN" -eq 1 ]]; then
	install_status="Would install"
	"$SCRIPT_DIR/restart-coreaudiod.sh" --dry-run
else
	install_status="Installed"
	"$SCRIPT_DIR/restart-coreaudiod.sh"
fi

cat <<EOF
$install_status: $DEST_BUNDLE

Verify:
  system_profiler SPAudioDataType | grep -A8 -i OpenSoundcard
EOF
