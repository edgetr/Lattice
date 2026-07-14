#!/usr/bin/env bash
# Lattice local build, package, test, and development release-check helper.
# Produces unsigned development app bundles only. Does not sign, notarize,
# staple, or embed credentials/identities.
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Lattice"
BUNDLE_ID="com.lattice.desktop"
# Development identity only — not a production marketing release.
APP_VERSION="0.1.0-dev"
APP_BUILD="1"
MIN_SYSTEM_VERSION="15.0"
EXPECTED_ARCH="arm64"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_NAME="AppIcon"
ICON_SOURCE="$ROOT_DIR/Resources/$ICON_NAME.png"
COMPANION_SOURCE="$ROOT_DIR/Resources/LatticeCompanion.png"
PACKAGE_STAGING_ROOT=""
PACKAGE_BACKUP_ROOT=""
PACKAGE_FINAL_BUNDLE="$APP_BUNDLE"
PACKAGE_PROMOTION_IN_PROGRESS=0
LOCK_FILE="${LATTICE_LOCK_FILE:-${TMPDIR:-/tmp}/lattice-build-and-run.lock}"
LOCK_PID_FILE="$LOCK_FILE"
LOCK_TOOL="${LATTICE_LOCK_TOOL:-/usr/bin/shlock}"
LOCK_WAIT_SECONDS="${LATTICE_LOCK_WAIT_SECONDS:-0.2}"
LOCK_WAIT_LIMIT="${LATTICE_LOCK_WAIT_LIMIT:-600}"
MANUAL_BUILD="$ROOT_DIR/.build/manual"
SDK_CANDIDATES=(
  "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
  "/Library/Developer/CommandLineTools/SDKs/MacOSX27.0.sdk"
  "/Library/Developer/CommandLineTools/SDKs/MacOSX27.sdk"
  "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
  "/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
  "/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk"
)

set_bundle_paths() {
  APP_BUNDLE="$1"
  APP_CONTENTS="$APP_BUNDLE/Contents"
  APP_MACOS="$APP_CONTENTS/MacOS"
  APP_RESOURCES="$APP_CONTENTS/Resources"
  APP_BINARY="$APP_MACOS/$APP_NAME"
  INFO_PLIST="$APP_CONTENTS/Info.plist"
}

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

cleanup_package_artifacts() {
  if [[ -n "$PACKAGE_BACKUP_ROOT" ]]; then
    local backup_bundle="$PACKAGE_BACKUP_ROOT/$APP_NAME.app"
    if path_exists "$backup_bundle"; then
      if [[ "$PACKAGE_PROMOTION_IN_PROGRESS" -eq 1 ]]; then
        rm -rf "$PACKAGE_FINAL_BUNDLE"
      fi
      if ! path_exists "$PACKAGE_FINAL_BUNDLE"; then
        mv "$backup_bundle" "$PACKAGE_FINAL_BUNDLE" || true
      fi
    fi
    rm -rf "$PACKAGE_BACKUP_ROOT"
    PACKAGE_BACKUP_ROOT=""
    PACKAGE_PROMOTION_IN_PROGRESS=0
  fi

  if [[ -n "$PACKAGE_STAGING_ROOT" ]]; then
    rm -rf "$PACKAGE_STAGING_ROOT"
    PACKAGE_STAGING_ROOT=""
  fi
}

set_bundle_paths "$APP_BUNDLE"

usage() {
  cat >&2 <<'USAGE'
usage: script/build_and_run.sh [mode]

Modes:
  run                Build, package, and open the app (default)
  --debug|debug      Build, package, and launch under lldb
  --logs|logs        Build, package, open the app, stream process logs
  --telemetry|telemetry
                     Build, package, open the app, stream subsystem logs
  --test|test        Non-destructive: run unit / core verification tests only
  --verify|verify    Non-destructive: build, package, validate resources + Info.plist
  --release-check|release-check
                     Non-destructive: tests + package validation + signing/notarization report

Notes:
  - Development builds are unsigned and not notarized.
  - This script never embeds signing credentials or notarization identities.
  - --test / --verify / --release-check do not launch Lattice or kill a running instance.
USAGE
  exit 2
}

acquire_lock() {
  if [[ ! -x "$LOCK_TOOL" ]]; then
    echo "Cannot acquire build lock: shlock unavailable at $LOCK_TOOL." >&2
    return 1
  fi

  local waited=0
  # shlock prepares PID record and publishes it with atomic link(2).
  # Stale-PID check/removal stays inside same protocol; shell never splits
  # lock acquisition from PID creation.
  while ! "$LOCK_TOOL" -f "$LOCK_FILE" -p "$$" >/dev/null 2>&1; do
    sleep "$LOCK_WAIT_SECONDS"
    waited=$((waited + 1))
    if [[ "$waited" -ge "$LOCK_WAIT_LIMIT" ]]; then
      echo "Timed out waiting for another Lattice build/run task to finish." >&2
      return 1
    fi
  done
}

release_lock() {
  if [[ -f "$LOCK_PID_FILE" ]] && [[ "$(cat "$LOCK_PID_FILE" 2>/dev/null || true)" == "$$" ]]; then
    rm -f "$LOCK_FILE"
  fi
}

on_exit() {
  cleanup_package_artifacts
  release_lock
}

have_swiftpm() {
  xcodebuild -version >/dev/null 2>&1 && swift package --version >/dev/null 2>&1
}

resolve_manual_sdk() {
  local candidate
  for candidate in "${SDK_CANDIDATES[@]}"; do
    if [[ -f "$candidate/SDKSettings.json" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  # Prefer the highest-versioned MacOSX*.sdk under CLT if present.
  local newest
  newest="$(ls -1d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -V | tail -1 || true)"
  if [[ -n "$newest" && -f "$newest/SDKSettings.json" ]]; then
    printf '%s\n' "$newest"
    return 0
  fi
  return 1
}

build_with_swiftpm() {
  echo "==> Building with Swift Package Manager"
  swift build
  BUILD_BINARY="$(swift build --show-bin-path)/$APP_NAME"
}

build_manual_core() {
  local sdk
  if ! sdk="$(resolve_manual_sdk)"; then
    echo "Lattice requires full Xcode or a complete macOS SDK. Swift Package Manager is unavailable." >&2
    exit 1
  fi
  echo "==> Building manually against SDK: $sdk"
  rm -rf "$MANUAL_BUILD"
  mkdir -p "$MANUAL_BUILD"
  # shellcheck disable=SC2086
  swiftc -sdk "$sdk" -target arm64-apple-macosx15.0 -parse-as-library -enable-testing \
    -module-cache-path "$MANUAL_BUILD/module-cache" -emit-module -emit-library -static \
    -module-name LatticeCore "$ROOT_DIR"/Sources/LatticeCore/*.swift \
    -emit-module-path "$MANUAL_BUILD/LatticeCore.swiftmodule" -o "$MANUAL_BUILD/libLatticeCore.a"
  CORE_BIN_PATH="$MANUAL_BUILD"
}

build_manual() {
  build_manual_core
  local sdk
  sdk="$(resolve_manual_sdk)"
  # shellcheck disable=SC2086
  swiftc -sdk "$sdk" -target arm64-apple-macosx15.0 -module-cache-path "$MANUAL_BUILD/module-cache" \
    -I "$MANUAL_BUILD" "$MANUAL_BUILD/libLatticeCore.a" -framework Security -framework LocalAuthentication \
    "$ROOT_DIR"/Sources/Lattice/*.swift -o "$MANUAL_BUILD/Lattice"
  BUILD_BINARY="$MANUAL_BUILD/Lattice"
}

ensure_core_library() {
  if have_swiftpm; then
    swift build --target LatticeCore
    CORE_BIN_PATH="$(swift build --show-bin-path)"
    return 0
  fi
  # Clean every fallback invocation; cache keys can miss source deletions and SDK/toolchain changes.
  build_manual_core
}

verify_fallback_test_inventory() {
  local expected_files=51
  local expected_tests=528
  local test_sources=("$ROOT_DIR"/Tests/LatticeCoreTests/*.swift)
  if [[ ! -e "${test_sources[0]}" ]]; then
    echo "FAIL: fallback test inventory missing Tests/LatticeCoreTests/*.swift" >&2
    return 1
  fi
  if [[ "${#test_sources[@]}" -ne "$expected_files" ]]; then
    echo "FAIL: fallback/native test-file parity changed (expected $expected_files, found ${#test_sources[@]})" >&2
    return 1
  fi

  local test_file test_count total_tests=0
  for test_file in "${test_sources[@]}"; do
    if ! /usr/bin/grep -q '^import Testing$' "$test_file"; then
      echo "FAIL: fallback test inventory found non-Swift-Testing file: $test_file" >&2
      return 1
    fi
    test_count="$(/usr/bin/grep -Ec '^[[:space:]]*@Test(\(|[[:space:]]|$)' "$test_file")"
    total_tests=$((total_tests + test_count))
  done
  if [[ "$total_tests" -ne "$expected_tests" ]]; then
    echo "FAIL: fallback/native test-declaration parity changed (expected $expected_tests, found $total_tests)" >&2
    return 1
  fi
  if [[ ! -s "$ROOT_DIR/script/verify_core.swift" ]]; then
    echo "FAIL: fallback verifier missing or empty: script/verify_core.swift" >&2
    return 1
  fi
  echo "Fallback inventory: ${#test_sources[@]} native test files / $total_tests native Swift Testing declarations; native declarations are not executed in fallback mode."
}

run_tests() {
  if have_swiftpm; then
    echo "==> Running native Swift Testing suite (non-destructive)"
    swift test
    echo "OK: native Swift Testing suite passed"
    return 0
  fi

  local sdk
  if ! sdk="$(resolve_manual_sdk)"; then
    echo "Cannot run tests: full Xcode/SwiftPM unavailable and no usable macOS SDK found." >&2
    exit 1
  fi

  echo "==> SwiftPM unavailable; running deterministic fallback core verification"
  echo "    Native Swift Testing suite is not run in fallback mode."
  verify_fallback_test_inventory
  ensure_core_library
  # shellcheck disable=SC2086
  if ! swiftc -parse-as-library -sdk "$sdk" -target arm64-apple-macosx15.0 \
    -module-cache-path "$MANUAL_BUILD/module-cache" \
    -I "$CORE_BIN_PATH" "$CORE_BIN_PATH/libLatticeCore.a" \
    "$ROOT_DIR/script/verify_core.swift" -o "$MANUAL_BUILD/verify_core"; then
    echo "FAIL: fallback verifier compilation failed" >&2
    return 1
  fi
  if ! "$MANUAL_BUILD/verify_core"; then
    echo "FAIL: fallback core verification failed" >&2
    return 1
  fi
  echo "OK: fallback core verification passed (native Swift Testing suite not run)"
}

build_binary() {
  if have_swiftpm; then
    build_with_swiftpm
  else
    build_manual
  fi
  if [[ ! -x "$BUILD_BINARY" ]]; then
    echo "Build failed: binary not found at $BUILD_BINARY" >&2
    exit 1
  fi
}

package_app() {
  local final_bundle="$APP_BUNDLE"
  PACKAGE_FINAL_BUNDLE="$final_bundle"
  mkdir -p "$DIST_DIR"
  PACKAGE_STAGING_ROOT="$(mktemp -d "$DIST_DIR/.${APP_NAME}.app-staging.XXXXXX")"
  set_bundle_paths "$PACKAGE_STAGING_ROOT/$APP_NAME.app"
  echo "==> Packaging $final_bundle (staging: $APP_BUNDLE)"
  mkdir -p "$APP_MACOS" "$APP_RESOURCES"
  cp "$BUILD_BINARY" "$APP_BINARY"
  chmod +x "$APP_BINARY"

  if [[ -f "$ICON_SOURCE" ]]; then
    local icon_width icon_height
    icon_width="$(/usr/bin/sips -g pixelWidth "$ICON_SOURCE" | awk '/pixelWidth:/ { print $2 }')"
    icon_height="$(/usr/bin/sips -g pixelHeight "$ICON_SOURCE" | awk '/pixelHeight:/ { print $2 }')"
    if [[ "$icon_width" != "$icon_height" || "$icon_width" -lt 1024 ]]; then
      echo "App icon must be square and at least 1024×1024 pixels (found ${icon_width}×${icon_height})." >&2
      exit 1
    fi
    local iconset
    iconset="$ROOT_DIR/.build/$ICON_NAME.iconset"
    rm -rf "$iconset"
    mkdir -p "$iconset"
    make_icon() {
      local points="$1"
      local suffix="$2"
      local pixels="$3"
      /usr/bin/sips -z "$pixels" "$pixels" "$ICON_SOURCE" --out "$iconset/icon_${points}x${points}${suffix}.png" >/dev/null
    }
    make_icon 16 "" 16
    make_icon 16 "@2x" 32
    make_icon 32 "" 32
    make_icon 32 "@2x" 64
    make_icon 128 "" 128
    make_icon 128 "@2x" 256
    make_icon 256 "" 256
    make_icon 256 "@2x" 512
    make_icon 512 "" 512
    make_icon 512 "@2x" 1024
    /usr/bin/iconutil -c icns "$iconset" -o "$APP_RESOURCES/$ICON_NAME.icns"
    [[ -s "$APP_RESOURCES/$ICON_NAME.icns" ]]
  fi

  if [[ -f "$COMPANION_SOURCE" ]]; then
    cp "$COMPANION_SOURCE" "$APP_RESOURCES/LatticeCompanion.png"
  fi

  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleIconFile</key><string>$ICON_NAME</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$APP_BUILD</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

  if ! verify_bundle; then
    echo "FAIL: staged app bundle validation failed; preserving existing $final_bundle" >&2
    set_bundle_paths "$final_bundle"
    cleanup_package_artifacts
    return 1
  fi

  local backup_root=""
  if path_exists "$final_bundle"; then
    backup_root="$(mktemp -d "$DIST_DIR/.${APP_NAME}.app-backup.XXXXXX")"
    PACKAGE_BACKUP_ROOT="$backup_root"
    PACKAGE_PROMOTION_IN_PROGRESS=1
    if ! mv "$final_bundle" "$backup_root/$APP_NAME.app"; then
      echo "FAIL: could not move existing app into transactional backup" >&2
      set_bundle_paths "$final_bundle"
      cleanup_package_artifacts
      return 1
    fi
  fi

  if ! mv "$APP_BUNDLE" "$final_bundle"; then
    echo "FAIL: could not promote staged app; preserving existing $final_bundle" >&2
    set_bundle_paths "$final_bundle"
    cleanup_package_artifacts
    return 1
  fi

  set_bundle_paths "$final_bundle"
  PACKAGE_PROMOTION_IN_PROGRESS=0
  cleanup_package_artifacts
  echo "OK: packaged app promoted transactionally to $APP_BUNDLE"
}

plist_print() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST"
}

expect_eq() {
  local label="$1"
  local actual="$2"
  local expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL: $label (expected '$expected', got '$actual')" >&2
    return 1
  fi
  echo "OK: $label = $actual"
}

verify_bundle() {
  echo "==> Verifying packaged app bundle"
  local failures=0

  if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "FAIL: app bundle missing at $APP_BUNDLE" >&2
    return 1
  fi
  if [[ ! -x "$APP_BINARY" ]]; then
    echo "FAIL: executable missing or not executable at $APP_BINARY" >&2
    failures=$((failures + 1))
  else
    echo "OK: executable present"
  fi

  if [[ ! -s "$APP_RESOURCES/$ICON_NAME.icns" ]]; then
    echo "FAIL: AppIcon.icns missing or empty" >&2
    failures=$((failures + 1))
  else
    echo "OK: AppIcon.icns present"
  fi

  if [[ ! -s "$APP_RESOURCES/LatticeCompanion.png" ]]; then
    echo "FAIL: LatticeCompanion.png missing or empty" >&2
    failures=$((failures + 1))
  else
    echo "OK: LatticeCompanion.png present"
  fi

  expect_eq "CFBundleIconFile" "$(plist_print CFBundleIconFile)" "$ICON_NAME" || failures=$((failures + 1))
  expect_eq "CFBundleIdentifier" "$(plist_print CFBundleIdentifier)" "$BUNDLE_ID" || failures=$((failures + 1))
  expect_eq "CFBundleName" "$(plist_print CFBundleName)" "$APP_NAME" || failures=$((failures + 1))
  expect_eq "CFBundleShortVersionString" "$(plist_print CFBundleShortVersionString)" "$APP_VERSION" || failures=$((failures + 1))
  expect_eq "CFBundleVersion" "$(plist_print CFBundleVersion)" "$APP_BUILD" || failures=$((failures + 1))
  expect_eq "LSMinimumSystemVersion" "$(plist_print LSMinimumSystemVersion)" "$MIN_SYSTEM_VERSION" || failures=$((failures + 1))

  local arch_info
  arch_info="$(/usr/bin/lipo -info "$APP_BINARY" 2>/dev/null || /usr/bin/file "$APP_BINARY")"
  if printf '%s' "$arch_info" | grep -Eq "(^| )${EXPECTED_ARCH}( |$)"; then
    echo "OK: architecture includes $EXPECTED_ARCH ($arch_info)"
  else
    echo "FAIL: expected architecture $EXPECTED_ARCH in binary (got: $arch_info)" >&2
    failures=$((failures + 1))
  fi

  if [[ "$failures" -ne 0 ]]; then
    echo "Bundle verification failed with $failures issue(s)." >&2
    return 1
  fi
  echo "OK: bundle verification passed"
}

report_signing_and_notarization() {
  echo "==> Signing / notarization report (truthful development status)"
  echo "Bundle: $APP_BUNDLE"
  echo "Expected distribution status: UNSIGNED DEVELOPMENT BUILD — not a production distributable"

  if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "Signing: cannot inspect — bundle missing"
    echo "Notarization: cannot inspect — bundle missing"
    return 1
  fi

  local codesign_out=0
  local codesign_text
  if codesign_text="$(/usr/bin/codesign -dv --verbose=4 "$APP_BUNDLE" 2>&1)"; then
    codesign_out=0
  else
    codesign_out=$?
  fi
  echo "---- codesign -dv --verbose=4 ----"
  printf '%s\n' "$codesign_text"

  if printf '%s' "$codesign_text" | grep -Eq 'Signature=(adhoc|null)|code object is not signed|not signed at all'; then
    echo "Signing summary: unsigned or ad-hoc only (no Developer ID / Apple Distribution identity)"
  elif printf '%s' "$codesign_text" | grep -q 'Authority='; then
    echo "Signing summary: signature material present (inspect Authority lines above)."
    echo "WARNING: this repository does not claim production distribution readiness from CI alone."
  else
    echo "Signing summary: no production signing identity reported (exit $codesign_out)"
  fi

  echo "---- Gatekeeper / notarization assessment ----"
  local spctl_text
  if spctl_text="$(/usr/sbin/spctl -a -vv -t exec "$APP_BUNDLE" 2>&1)"; then
    printf '%s\n' "$spctl_text"
    echo "Gatekeeper summary: assessment returned success; still not claimed as a Lattice production release."
  else
    printf '%s\n' "$spctl_text"
    echo "Gatekeeper summary: not accepted as a notarized production app (expected for local/CI development builds)"
  fi

  if command -v xcrun >/dev/null 2>&1; then
    echo "---- stapler validate ----"
    if /usr/bin/xcrun stapler validate "$APP_BUNDLE" >/dev/null 2>&1; then
      echo "Notarization summary: stapler reports a valid ticket (unusual for this development path)."
    else
      echo "Notarization summary: no valid notarization staple (expected). Not notarized."
    fi
  else
    echo "Notarization summary: xcrun unavailable; cannot staple-validate. Treat as not notarized."
  fi

  echo "Release claim: Lattice does NOT ship a production-signed, notarized distributable from this script or CI."
  echo "Artifact label if uploaded: unsigned-development-not-for-distribution"
}

open_app() { /usr/bin/open "$APP_BUNDLE"; }

build_and_package() {
  build_binary
  package_app
}

# --- main ---
case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--test|test|--verify|verify|--release-check|release-check) ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac

acquire_lock
trap on_exit EXIT
trap 'release_lock; exit 130' INT
trap 'release_lock; exit 143' TERM

if [[ "$MODE" == "run" || "$MODE" == "--debug" || "$MODE" == "debug" || "$MODE" == "--logs" || "$MODE" == "logs" || "$MODE" == "--telemetry" || "$MODE" == "telemetry" ]]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

cd "$ROOT_DIR"

case "$MODE" in
  --test|test)
    run_tests
    ;;
  --verify|verify)
    build_and_package
    verify_bundle
    ;;
  --release-check|release-check)
    run_tests
    build_and_package
    verify_bundle
    report_signing_and_notarization
    echo "==> Release check complete (development / non-production)"
    ;;
  run)
    build_and_package
    open_app
    ;;
  --debug|debug)
    build_and_package
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    build_and_package
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    build_and_package
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  *)
    usage
    ;;
esac
