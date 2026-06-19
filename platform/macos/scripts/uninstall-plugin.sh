#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: uninstall-plugin.sh [--dry-run] [--system]

Removes the installed OpenSoundcard CoreAudio HAL driver.

Defaults to the current user's HAL plug-in directory:
  ~/Library/Audio/Plug-Ins/HAL

Options:
  --dry-run   Print actions without removing files.
  --system    Remove from /Library/Audio/Plug-Ins/HAL. This usually needs sudo.

Environment overrides:
  OSC_HAL_DIR   HAL plug-in install directory.
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_NAME="OpenSoundcard.driver"
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

	if [[ ! -e "$DEST_BUNDLE" || -w "$INSTALL_DIR" ]]; then
		"$@"
		return 0
	fi

	echo "Using sudo because $INSTALL_DIR is not writable by the current user."
	sudo "$@"
}

if [[ "$INSTALL_DIR" == /Library/* ]]; then
	echo "Removing from the system HAL directory. macOS usually requires sudo here."
fi

removed_bundle=0

if [[ "$DRY_RUN" -eq 1 ]]; then
	run rm -rf "$DEST_BUNDLE"
	echo "Would remove: $DEST_BUNDLE"
	removed_bundle=1
elif [[ ! -e "$DEST_BUNDLE" ]]; then
	echo "No installed bundle found at: $DEST_BUNDLE"
else
	run_with_optional_sudo rm -rf "$DEST_BUNDLE"
	echo "Removed: $DEST_BUNDLE"
	removed_bundle=1
fi

if [[ "$removed_bundle" -eq 1 ]]; then
	if [[ "$DRY_RUN" -eq 1 ]]; then
		"$SCRIPT_DIR/restart-coreaudiod.sh" --dry-run
	else
		"$SCRIPT_DIR/restart-coreaudiod.sh"
	fi
fi

cat <<EOF

Verify removal:
  system_profiler SPAudioDataType | grep -A8 -i OpenSoundcard
EOF
