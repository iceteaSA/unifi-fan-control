#!/bin/bash
###############################################################################
# SATA standby tests: idle drives stay cached and rejoin without a restart.
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

# ── Scenario 1: an initially sleeping SATA drive joins after it wakes ───────
# Break caught: skipping standby at detection permanently removes the drive.
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
touch "$FAN_CONTROL_DRIVE_DEV_DIR/sda" "$SANDBOX/smartctl_standby_sda"
set_smartctl_temperature sda 70
prepare_drive_polling

start_daemon
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "0" 10 || fail "sleeping drive should not establish a floor"
/bin/sleep 31
rm "$SANDBOX/smartctl_standby_sda"
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "255" 20 || fail "woken drive did not establish a floor without restart"
assert_log_count "sda is asleep; excluded from floor" "1"
assert_contains "$(cat "$SANDBOX/syslog")" "sda woke; included in floor" "wake-up should be logged: "

echo "  ✓ Scenario ${scenario}: sleeping SATA drive joins after wake-up"

stop_daemon
cleanup_sandbox

# ── Scenario 2: all sleeping drives are quiet and do not look broken ────────
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
for device in sda sdb; do
    touch "$FAN_CONTROL_DRIVE_DEV_DIR/$device" "$SANDBOX/smartctl_standby_${device}"
    set_smartctl_temperature "$device" 70
done
prepare_drive_polling

start_daemon
/bin/sleep 31
assert_eq "$(get_pwm)" "0" "all sleeping drives must leave the floor at zero: "
assert_log_count "is asleep; excluded from floor" "2"
if grep -q "All cached drives unreadable; floor disabled" "$SANDBOX/syslog"; then
    fail "sleeping drives must not be reported as unreadable"
fi

echo "  ✓ Scenario ${scenario}: all sleeping drives remain quiet and healthy"

stop_daemon
cleanup_sandbox

# ── Scenario 3: standby and a genuine read failure are distinct states ──────
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
touch "$FAN_CONTROL_DRIVE_DEV_DIR/sda" "$FAN_CONTROL_DRIVE_DEV_DIR/sdb"
touch "$SANDBOX/smartctl_standby_sda" "$SANDBOX/smartctl_fail_sdb"
set_smartctl_temperature sda 70
set_smartctl_temperature sdb 70

start_daemon
wait_for_log "sda is asleep; excluded from floor" 10 || fail "standby state was not logged"
wait_for_log "sdb read failed; excluding it from floor" 10 || fail "failed state was not logged"
if grep -q "All cached drives unreadable; floor disabled" "$SANDBOX/syslog"; then
    fail "mixed standby and failure must not be reported as all unreadable"
fi

echo "  ✓ Scenario ${scenario}: standby and failure remain distinguishable"

stop_daemon
cleanup_sandbox

echo "  All ${scenario} standby handling scenarios passed."
