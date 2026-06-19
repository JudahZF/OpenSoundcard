#!/usr/bin/env bash
set -euo pipefail

usage() {
	cat <<'USAGE'
Usage: restart-coreaudiod.sh [--dry-run]

Restarts macOS coreaudiod so CoreAudio reloads HAL plug-ins.
This is limited to the CoreAudio daemon. It may briefly interrupt audio.

Options:
  --dry-run   Print the restart command without running it.
USAGE
}

DRY_RUN=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	--dry-run)
		DRY_RUN=1
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

if [[ "$DRY_RUN" -eq 1 ]]; then
	echo "dry-run: sudo launchctl kickstart -k system/com.apple.audio.coreaudiod"
	exit 0
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
	echo "error: coreaudiod can only be restarted on macOS." >&2
	exit 1
fi

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
	launchctl kickstart -k system/com.apple.audio.coreaudiod
else
	echo "Restarting coreaudiod usually requires sudo."
	sudo launchctl kickstart -k system/com.apple.audio.coreaudiod
fi

echo "coreaudiod restart requested."
