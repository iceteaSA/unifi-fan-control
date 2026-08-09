#!/bin/bash
###############################################################################
# Drive recovery tests: unreadable drives stay cached and rejoin without restart.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

set_smartctl_temperature() {
    local device="$1"
    local temperature="$2"

    cat >"$SANDBOX/smartctl_response_${device}" <<JSON
{"temperature":{"current":${temperature},"warning":83}}
JSON
}

prepare_drive_polling() {
    cat >>"$SANDBOX/config" <<'CONFIG'
DRIVE_CHECK_INTERVAL=15
CONFIG
}

assert_log_count() {
    local pattern="$1"
    local expected="$2"
    local actual

    actual=$(grep -c "$pattern" "$SANDBOX/syslog" || true)
    assert_eq "$actual" "$expected" "log count for ${pattern}: "
}

# ── Scenario 1: an initially unreadable SATA drive joins after recovery ─────
# Break caught: caching only successful startup reads prevents later recovery.
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
touch "$FAN_CONTROL_DRIVE_DEV_DIR/sda" "$SANDBOX/smartctl_fail_sda"
set_smartctl_temperature sda 70
prepare_drive_polling

start_daemon
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "0" 10 || fail "unreadable drive should not establish a floor"
/bin/sleep 31
assert_log_count "sda read failed; excluding it from floor" "1"
assert_log_count "All cached drives unreadable; floor disabled" "1"
rm "$SANDBOX/smartctl_fail_sda"
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "255" 20 || fail "recovered drive did not establish a floor without restart"
/bin/sleep 31
assert_log_count "sda read recovered" "1"

echo "  ✓ Scenario ${scenario}: unreadable SATA drive joins after recovery"

stop_daemon
cleanup_sandbox

echo "  All ${scenario} drive recovery scenarios passed."
