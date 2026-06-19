#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
HEADER_PATH="$REPO_ROOT/platform/macos/include/opensoundcard_ffi.h"

if ! command -v cbindgen >/dev/null 2>&1; then
	echo "cbindgen is required. Run 'direnv allow' or 'nix develop' first." >&2
	exit 1
fi

mkdir -p "$(dirname "$HEADER_PATH")"

cd "$REPO_ROOT"
cbindgen \
	--config cbindgen.toml \
	--crate opensoundcard-core \
	--output "$HEADER_PATH"
