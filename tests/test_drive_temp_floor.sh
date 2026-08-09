#!/bin/bash
###############################################################################
# Drive temperature floor tests: silent absence, unit conversion, and failures.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

assert_no_drive_logs() {
    local logs="$1"
    if grep -q 'DRIVE:' <<<"$logs" || grep -q 'DETECT:.*drive' <<<"$logs"; then
        fail "no-drive startup emitted drive detection logs"
    fi
}

prepare_second_start() {
    start_daemon
    stop_daemon
    : >"$SANDBOX/syslog"
}

# ── Scenario 1: no drive is as silent as an explicitly disabled feature ──────
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
prepare_second_start
echo 'DRIVE_TEMP_ENABLED=false' >>"$SANDBOX/config"
start_daemon
/bin/sleep 1
disabled_pwm=$(get_pwm)
stop_daemon
cleanup_sandbox

setup_sandbox
echo "45" >"$SANDBOX/cputemp"
prepare_second_start
for param in DRIVE_TEMP_ENABLED DRIVE_MIN_TEMP DRIVE_MAX_TEMP DRIVE_CHECK_INTERVAL; do
    grep -q "^${param}=" "$SANDBOX/config" || fail "fresh config missing ${param}"
done
start_daemon
/bin/sleep 1
auto_logs=$(cat "$SANDBOX/syslog")
auto_pwm=$(get_pwm)
assert_no_drive_logs "$auto_logs"
assert_eq "$auto_pwm" "$disabled_pwm" "no-drive PWM must match disabled feature: "
[[ ! -s "$SANDBOX/drive_calls" ]] || fail "no-drive startup invoked a drive tool"

echo "  ✓ Scenario ${scenario}: no drive is silent and PWM-identical to disabled"

stop_daemon
cleanup_sandbox

# ── Scenario 2: a hot drive lifts PWM while the CPU remains in OFF ───────────
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
touch "$FAN_CONTROL_DRIVE_DEV_DIR/nvme0n1"
cat >"$SANDBOX/nvme_response" <<'JSON'
{"temperature":330,"wctemp":83}
JSON

start_daemon
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0 10 || fail "hot drive did not lift PWM from OFF"
assert_contains "$(cat "$SANDBOX/syslog")" "DRIVE:" "hot drive should be logged: "

echo "  ✓ Scenario ${scenario}: hot drive lifts PWM from OFF"

stop_daemon
cleanup_sandbox

# ── Scenario 3: NVMe JSON Kelvin 320 converts to a cool 47°C ────────────────
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
touch "$FAN_CONTROL_DRIVE_DEV_DIR/nvme0n1"
cat >"$SANDBOX/nvme_response" <<'JSON'
{"temperature":320,"wctemp":83}
JSON

start_daemon
/bin/sleep 1
assert_eq "$(get_pwm)" "0" "NVMe Kelvin 320 must convert to cool 47°C: "
assert_contains "$(cat "$SANDBOX/syslog")" "47°C" "NVMe Kelvin conversion should log 47°C: "

echo "  ✓ Scenario ${scenario}: NVMe 320K converts to 47°C"

stop_daemon
cleanup_sandbox

# ── Scenario 4: smartctl JSON Celsius 47 stays at 47°C ─────────────────────
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
touch "$FAN_CONTROL_DRIVE_DEV_DIR/nvme0n1"
touch "$SANDBOX/nvme_fail"
cat >"$SANDBOX/smartctl_response" <<'JSON'
{"temperature":{"current":47,"warning":83}}
JSON

start_daemon
/bin/sleep 1
assert_eq "$(get_pwm)" "0" "smartctl Celsius 47 must remain cool: "
assert_contains "$(cat "$SANDBOX/syslog")" "47°C" "smartctl Celsius value should log 47°C: "

echo "  ✓ Scenario ${scenario}: smartctl 47°C remains 47°C"

stop_daemon
cleanup_sandbox

# ── Scenario 5: a cool drive does not override the CPU curve ─────────────────
scenario=$((scenario + 1))
setup_sandbox
echo "75" >"$SANDBOX/cputemp"
touch "$FAN_CONTROL_DRIVE_DEV_DIR/nvme0n1"
cat >"$SANDBOX/nvme_response" <<'JSON'
{"temperature":320,"wctemp":83}
JSON

start_daemon
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0 10 || fail "hot CPU should control PWM with cool drive"

echo "  ✓ Scenario ${scenario}: cool drive leaves hot CPU in control"

stop_daemon
cleanup_sandbox

# ── Scenario 6: a failed read drops the floor without forcing MAX_PWM ────────
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
touch "$FAN_CONTROL_DRIVE_DEV_DIR/nvme0n1"
cat >"$SANDBOX/nvme_response" <<'JSON'
{"temperature":330,"wctemp":83}
JSON
cat >>"$SANDBOX/config" <<'CONFIG'
DRIVE_CHECK_INTERVAL=15
CONFIG

start_daemon
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0 10 || fail "hot drive should establish a floor"
touch "$SANDBOX/nvme_fail"
wait_for_log "DRIVE:.*read failed" 20 || fail "failed drive read was not logged"
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "0" 10 || fail "failed drive read should drop floor"
assert_eq "$(get_pwm)" "0" "failed drive read must not force MAX_PWM: "

echo "  ✓ Scenario ${scenario}: drive read failure drops floor without MAX_PWM"

stop_daemon
cleanup_sandbox

echo "  All ${scenario} drive temperature floor scenarios passed."
