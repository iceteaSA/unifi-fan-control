#!/bin/bash
###############################################################################
# Drive threshold reporting and uncontrolled PWM startup warnings.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

# ── Scenario 1: smartctl reports an NVMe warning threshold ─────────────────
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
touch "$FAN_CONTROL_DRIVE_DEV_DIR/nvme0n1" "$SANDBOX/nvme_fail"
cat >"$SANDBOX/smartctl_response" <<'JSON'
{
  "temperature": {"current": 47},
  "unrelated": {"warning": 90},
  "nvme_composite_temperature_threshold": {"warning": 83, "critical": 85},
  "nvme_smart_health_information_log": {"temperature": 47, "warning_temp_time": 0}
}
JSON

start_daemon
wait_for_log 'DRIVE:.*wctemp=83°C' 10 || fail "smartctl warning threshold was not logged"
assert_contains "$(cat "$SANDBOX/syslog")" 'wctemp=83°C' "smartctl threshold should retain Celsius format: "
assert_contains "$(cat "$SANDBOX/drive_calls")" 'smartctl -j -a' "smartctl must request the NVMe controller threshold: "

echo "  ✓ Scenario ${scenario}: smartctl NVMe threshold is reported"

stop_daemon
cleanup_sandbox

# ── Scenario 2: ATA smartctl data without a threshold says not reported ─────
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
touch "$FAN_CONTROL_DRIVE_DEV_DIR/sda"
cat >"$SANDBOX/smartctl_response" <<'JSON'
{
  "temperature": {"current": 47},
  "ata_smart_attributes": {"table": [{"id": 194, "name": "Temperature_Celsius", "raw": {"value": 47}}]}
}
JSON

start_daemon
wait_for_log 'DRIVE:.*wctemp=not reported' 10 || fail "missing smartctl threshold was not described honestly"
logs=$(cat "$SANDBOX/syslog")
assert_contains "$logs" 'wctemp=not reported' "missing threshold should say not reported: "
if grep -q 'wctemp=not reported°C\|wctemp=unknown' <<<"$logs"; then
    fail "missing threshold log included a unit or implied a failed read"
fi

echo "  ✓ Scenario ${scenario}: absent smartctl threshold is reported honestly"

stop_daemon
cleanup_sandbox

# ── Scenario 3: stopped writable PWM is controlled ──────────────────────────
scenario=$((scenario + 1))
setup_sandbox
echo "70" >"$SANDBOX/cputemp"
echo 25 >"$SANDBOX/hwmon/hwmon0/pwm2"
echo 0 >"$SANDBOX/hwmon/hwmon0/fan2_input"

start_daemon
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm2" 0
logs=$(cat "$SANDBOX/syslog")
assert_contains "$logs" 'pwm2.*0 RPM (unknown, controlled)' "stopped writable PWM should remain controlled: "

echo "  ✓ Scenario ${scenario}: stopped writable PWM is controlled"

stop_daemon
cleanup_sandbox

# ── Scenario 4: controlled PWM channels stay silent ─────────────────────────
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
echo 25 >"$SANDBOX/hwmon/hwmon0/pwm1"
echo 0 >"$SANDBOX/hwmon/hwmon0/pwm2"
echo 0 >"$SANDBOX/hwmon/hwmon0/fan2_input"

start_daemon
/bin/sleep 1
logs=$(cat "$SANDBOX/syslog")
if grep -q 'DETECT:.*not controlled' <<<"$logs"; then
    fail "controlled PWM channel emitted an uncontrolled warning"
fi

echo "  ✓ Scenario ${scenario}: controlled PWM channels stay silent"

stop_daemon
cleanup_sandbox

echo "  All ${scenario} drive reporting and orphaned PWM scenarios passed."
