#!/bin/bash
###############################################################################
# Multi-drive temperature floor tests: hottest readable drive controls the fan.
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

set_nvme_temperature() {
    local device="$1"
    local temperature_kelvin="$2"

    cat >"$SANDBOX/nvme_response_${device}" <<JSON
{"temperature":${temperature_kelvin},"wctemp":356}
JSON
}

prepare_drive_polling() {
    cat >>"$SANDBOX/config" <<'CONFIG'
DRIVE_CHECK_INTERVAL=15
CONFIG
}

# ── Scenario 1: the hottest of four SATA drives determines the floor ────────
# Break caught: returning after the first readable drive keeps sda in control.
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
for device in sda sdb sdc sdd; do
    touch "$FAN_CONTROL_DRIVE_DEV_DIR/$device"
done
set_smartctl_temperature sda 55
set_smartctl_temperature sdb 70
set_smartctl_temperature sdc 60
set_smartctl_temperature sdd 65

start_daemon
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "255" 10 || fail "hottest SATA drive did not establish MAX_PWM floor"
for device in sda sdb sdc sdd; do
    assert_contains "$(cat "$SANDBOX/syslog")" "Detected .*${device}" "startup should report ${device}: "
done
assert_contains "$(cat "$SANDBOX/drive_calls")" "smartctl -j -a .*sda" "SATA polling must read the SMART temperature: "
assert_contains "$(cat "$SANDBOX/syslog")" "sdb drives floor" "hottest drive should be attributable: "

echo "  ✓ Scenario ${scenario}: hottest of four SATA drives controls the floor"

stop_daemon
cleanup_sandbox

# ── Scenario 2: a new hottest drive takes control on the next poll ──────────
# Break caught: polling only the startup drive cannot follow a new hottest disk.
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
for device in sda sdb sdc sdd; do
    touch "$FAN_CONTROL_DRIVE_DEV_DIR/$device"
done
set_smartctl_temperature sda 65
set_smartctl_temperature sdb 60
set_smartctl_temperature sdc 55
set_smartctl_temperature sdd 50
prepare_drive_polling

start_daemon
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "214" 10 || fail "initial hottest drive did not establish its floor"
set_smartctl_temperature sda 55
set_smartctl_temperature sdb 70
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "255" 20 || fail "new hottest drive did not take control"
assert_contains "$(cat "$SANDBOX/syslog")" "sdb drives floor" "new hottest drive should be attributable: "

echo "  ✓ Scenario ${scenario}: hottest drive changes between polls"

stop_daemon
cleanup_sandbox

# ── Scenario 3: one failed read leaves other drives controlling the floor ────
# Break caught: one unreadable drive must not clear a floor still supported by peers.
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
for device in sda sdb sdc sdd; do
    touch "$FAN_CONTROL_DRIVE_DEV_DIR/$device"
done
set_smartctl_temperature sda 70
set_smartctl_temperature sdb 65
set_smartctl_temperature sdc 60
set_smartctl_temperature sdd 55
prepare_drive_polling

start_daemon
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "255" 10 || fail "initial hot drive did not establish MAX_PWM floor"
touch "$SANDBOX/smartctl_fail_sda"
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "214" 20 || fail "remaining drives did not maintain the floor"
assert_contains "$(cat "$SANDBOX/syslog")" "sda read failed; excluding it from floor" "failed drive should be logged once: "
rm "$SANDBOX/smartctl_fail_sda"
wait_for_log "DRIVE: .*sda read recovered" 20 || fail "recovered drive was not logged"

echo "  ✓ Scenario ${scenario}: partial drive failure preserves the floor"

stop_daemon
cleanup_sandbox

# ── Scenario 4: all failed reads clear the floor without a CPU-style failsafe ─
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
for device in sda sdb sdc sdd; do
    touch "$FAN_CONTROL_DRIVE_DEV_DIR/$device"
    set_smartctl_temperature "$device" 70
done
prepare_drive_polling

start_daemon
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "255" 10 || fail "hot drives did not establish MAX_PWM floor"
for device in sda sdb sdc sdd; do
    touch "$SANDBOX/smartctl_fail_${device}"
done
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "0" 20 || fail "all unreadable drives did not clear the floor"
assert_eq "$(get_pwm)" "0" "all unreadable drive reads must not force MAX_PWM: "

echo "  ✓ Scenario ${scenario}: all failed drives clear the floor without MAX_PWM"

stop_daemon
cleanup_sandbox

# ── Scenario 5: hottest wins across NVMe and SATA media ─────────────────────
# Break caught: probing NVMe before SATA must not make cool NVMe win over hot SATA.
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
touch "$FAN_CONTROL_DRIVE_DEV_DIR/nvme0n1" "$FAN_CONTROL_DRIVE_DEV_DIR/sda"
set_nvme_temperature nvme0n1 320
set_smartctl_temperature sda 70

start_daemon
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "255" 10 || fail "hot SATA drive did not outrank cool NVMe drive"
assert_contains "$(cat "$SANDBOX/syslog")" "sda drives floor" "hot SATA drive should be attributable: "

echo "  ✓ Scenario ${scenario}: hottest drive wins across NVMe and SATA"

stop_daemon
cleanup_sandbox

echo "  All ${scenario} multi-drive temperature floor scenarios passed."
