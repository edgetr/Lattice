#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source <(sed '/^# --- main ---/,$d' "$SCRIPT_DIR/build_and_run.sh")

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lattice-packaging-transaction.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

DIST_DIR="$TEST_ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
set_bundle_paths "$APP_BUNDLE"
ICON_SOURCE="$TEST_ROOT/missing-icon.png"
COMPANION_SOURCE="$TEST_ROOT/missing-companion.png"

BUILD_BINARY="$TEST_ROOT/Lattice"
printf '#!/bin/sh\nexit 0\n' > "$BUILD_BINARY"
chmod +x "$BUILD_BINARY"

verify_bundle() {
  [[ -x "$APP_BINARY" ]]
  if [[ "${FAIL_VALIDATION:-0}" -eq 1 ]]; then
    return 1
  fi
}

mkdir -p "$APP_BUNDLE/Contents"
printf 'last-good\n' > "$APP_BUNDLE/Contents/last-good.marker"

if (FAIL_VALIDATION=1 package_app); then
  echo "FAIL: invalid staged bundle was promoted" >&2
  exit 1
fi
[[ "$(<"$APP_BUNDLE/Contents/last-good.marker")" == "last-good" ]]
[[ ! -e "$DIST_DIR/.${APP_NAME}.app-staging."* ]]

if (
  mv() {
    if [[ "${FAIL_PROMOTION:-0}" -eq 1 && "$1" == "$PACKAGE_STAGING_ROOT/"* ]]; then
      FAIL_PROMOTION=0
      return 1
    fi
    command mv "$@"
  }
  FAIL_PROMOTION=1
  package_app
); then
  echo "FAIL: promotion failure unexpectedly succeeded" >&2
  exit 1
fi
[[ "$(<"$APP_BUNDLE/Contents/last-good.marker")" == "last-good" ]]
[[ ! -e "$DIST_DIR/.${APP_NAME}.app-staging."* ]]
[[ ! -e "$DIST_DIR/.${APP_NAME}.app-backup."* ]]

package_app
[[ ! -e "$APP_BUNDLE/Contents/last-good.marker" ]]
[[ -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]]
[[ -s "$APP_BUNDLE/Contents/Info.plist" ]]
[[ ! -e "$DIST_DIR/.${APP_NAME}.app-staging."* ]]
[[ ! -e "$DIST_DIR/.${APP_NAME}.app-backup."* ]]

echo "OK: packaging preserves last good app on validation failure and promotes valid app"
