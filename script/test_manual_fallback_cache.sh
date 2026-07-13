#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load build functions without entering build_and_run.sh main dispatch.
source <(sed '/^# --- main ---/,$d' "$SCRIPT_DIR/build_and_run.sh")
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

verify_fallback_test_inventory

TEST_SDK="/fake/macos-sdk"
MANUAL_BUILD="$(mktemp -d "${TMPDIR:-/tmp}/lattice-manual-cache-test.XXXXXX")"
trap 'rm -rf "$MANUAL_BUILD"' EXIT

resolve_manual_sdk() { printf '%s\n' "$TEST_SDK"; }
have_swiftpm() { return 1; }

swiftc() {
  local index
  for ((index = 1; index <= $#; index += 1)); do
    case "${!index}" in
      -emit-module-path|-o)
        index=$((index + 1))
        printf x > "${!index}"
        ;;
    esac
  done
}

mkdir -p "$MANUAL_BUILD"
: > "$MANUAL_BUILD/stale-source-output"
ensure_core_library
[[ ! -e "$MANUAL_BUILD/stale-source-output" ]]
[[ -s "$MANUAL_BUILD/libLatticeCore.a" ]]
[[ -s "$MANUAL_BUILD/LatticeCore.swiftmodule" ]]

: > "$MANUAL_BUILD/stale-toolchain-output"
ensure_core_library
[[ ! -e "$MANUAL_BUILD/stale-toolchain-output" ]]

echo "OK: fallback inventory fail-closed and manual cache clean-rebuild pass"
