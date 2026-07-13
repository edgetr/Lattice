#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_SOURCE="$SCRIPT_DIR/build_and_run.sh"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lattice-build-lock-test.XXXXXX")"
TEST_LOCK_FILE="$TEST_ROOT/lock"
CRITICAL_SECTION="$TEST_ROOT/critical-section"
FAILURE_FILE="$TEST_ROOT/failure"
trap 'rm -rf "$TEST_ROOT"' EXIT

# A dead PID must be reclaimed by shlock, without any observer seeing an
# empty/partial PID record while contenders replace it.
printf '%s\n' 999999999 >"$TEST_LOCK_FILE"

worker() {
  LATTICE_LOCK_FILE="$TEST_LOCK_FILE" \
  LATTICE_LOCK_TOOL=/usr/bin/shlock \
  LATTICE_LOCK_WAIT_SECONDS=0.01 \
  LATTICE_LOCK_WAIT_LIMIT=500 \
  LATTICE_TEST_CRITICAL_SECTION="$CRITICAL_SECTION" \
  LATTICE_TEST_FAILURE_FILE="$FAILURE_FILE" \
  bash -c '
    set -euo pipefail
    source <(sed "/^# --- main ---/,\$d" "$1")
    acquire_lock
    trap release_lock EXIT

    owner="$(cat "$LOCK_PID_FILE")"
    if [[ ! "$owner" =~ ^[0-9]+$ || "$owner" != "$$" ]]; then
      printf "bad published owner: %s (process %s)\n" "$owner" "$$" >"$LATTICE_TEST_FAILURE_FILE"
      exit 1
    fi

    if ! mkdir "$LATTICE_TEST_CRITICAL_SECTION" 2>/dev/null; then
      printf "concurrent critical section entry by process %s\n" "$$" >"$LATTICE_TEST_FAILURE_FILE"
      exit 1
    fi
    sleep 0.01
    if [[ "$(cat "$LOCK_PID_FILE")" != "$$" ]]; then
      printf "owner changed while lock held: %s (process %s)\n" "$(cat "$LOCK_PID_FILE")" "$$" >"$LATTICE_TEST_FAILURE_FILE"
      rmdir "$LATTICE_TEST_CRITICAL_SECTION"
      exit 1
    fi
    rmdir "$LATTICE_TEST_CRITICAL_SECTION"
  ' bash "$SCRIPT_SOURCE"
}

# Poll while many independent processes acquire/release the same lock. The
# critical-section mkdir catches two live owners; PID assertions catch
# metadata publication/replacement races.
monitor_lock_metadata() {
  for _ in $(seq 1 20000); do
    if [[ -e "$TEST_LOCK_FILE" ]]; then
      local owner
      if ! owner="$(cat "$TEST_LOCK_FILE" 2>/dev/null)"; then
        continue
      fi
      if [[ ! "$owner" =~ ^[0-9]+$ ]]; then
        printf 'partial lock metadata observed: %q\n' "$owner" >"$FAILURE_FILE"
        return 1
      fi
    fi
  done
}

monitor_lock_metadata &
monitor_pid=$!
worker_pids=()
for _ in $(seq 1 24); do
  worker &
  worker_pids+=("$!")
done

status=0
for pid in "${worker_pids[@]}"; do
  wait "$pid" || status=1
done
wait "$monitor_pid" || status=1
if [[ "$status" -ne 0 || -e "$FAILURE_FILE" ]]; then
  cat "$FAILURE_FILE" 2>/dev/null || true
  exit 1
fi
if [[ -e "$TEST_LOCK_FILE" ]]; then
  echo "lock survived all owners" >&2
  exit 1
fi

# A non-owner release must not delete a live owner's lock record.
source <(sed '/^# --- main ---/,$d' "$SCRIPT_SOURCE")
LOCK_FILE="$TEST_LOCK_FILE"
LOCK_PID_FILE="$TEST_LOCK_FILE"
sleep 2 &
live_pid=$!
printf '%s\n' "$live_pid" >"$TEST_LOCK_FILE"
release_lock
[[ "$(cat "$TEST_LOCK_FILE")" == "$live_pid" ]]
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true
rm -f "$TEST_LOCK_FILE"

echo "OK: atomic build-lock PID publication and stale-PID contention evidence passed"
