#!/bin/bash
###############################################################################
# Uninstaller behavior tests — sandbox every path the root-owned script writes.
###############################################################################
set -euo pipefail

# shellcheck source=tests/lib/harness.sh
source "$(dirname "$0")/lib/harness.sh"

UNINSTALLER="$REPO_ROOT/uninstall.sh"
REAL_RM=$(command -v rm)
UNINSTALL_OUTPUT=""

trap teardown_sandbox EXIT

install_stubs() {
    cat >"$SANDBOX/bin/id" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-u" ]]; then
    echo 0
    exit 0
fi
exec /usr/bin/id "$@"
STUB
    chmod +x "$SANDBOX/bin/id"

    cat >"$SANDBOX/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SANDBOX/systemctl.log"
STUB
    chmod +x "$SANDBOX/bin/systemctl"

    cat >"$SANDBOX/bin/rm" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
    case "\$arg" in
        /etc/systemd/system/fan-control.service|/var/run/fan-control.pid|/data/fan-control)
            exit 1
            ;;
    esac
done
exec "$REAL_RM" "\$@"
STUB
    chmod +x "$SANDBOX/bin/rm"
}

prepare_case() {
    cleanup_sandbox
    setup_sandbox
    install_stubs

    export FAN_CONTROL_HWMON_BASE="$SANDBOX/hwmon"
    export FAN_CONTROL_INSTALL_DIR="$SANDBOX/install"
    export FAN_CONTROL_SERVICE_FILE="$SANDBOX/systemd/fan-control.service"

    rm -rf "$FAN_CONTROL_HWMON_BASE"
    mkdir -p "$FAN_CONTROL_HWMON_BASE" "$FAN_CONTROL_INSTALL_DIR" \
        "$(dirname "$FAN_CONTROL_SERVICE_FILE")" "$(dirname "$FAN_CONTROL_PID_FILE")"
    printf 'installed data\n' >"$FAN_CONTROL_INSTALL_DIR/config"
    printf 'service\n' >"$FAN_CONTROL_SERVICE_FILE"
    printf '1234\n' >"$FAN_CONTROL_PID_FILE"
}

run_uninstaller() {
    if ! UNINSTALL_OUTPUT=$(bash "$UNINSTALLER" 2>&1); then
        printf '%s\n' "$UNINSTALL_OUTPUT" >&2
        fail "uninstall.sh exited unsuccessfully"
    fi
}

assert_removed() {
    local path="$1"
    [[ ! -e "$path" ]] || fail "expected removal of $path"
}

assert_system_files_removed() {
    assert_removed "$FAN_CONTROL_INSTALL_DIR"
    assert_removed "$FAN_CONTROL_SERVICE_FILE"
    assert_removed "$FAN_CONTROL_PID_FILE"
}

test_class_directory_pwm_reset() {
    prepare_case
    mkdir -p "$FAN_CONTROL_HWMON_BASE/hwmon0"
    printf '127\n' >"$FAN_CONTROL_HWMON_BASE/hwmon0/pwm1"

    run_uninstaller

    assert_eq "$(cat "$FAN_CONTROL_HWMON_BASE/hwmon0/pwm1")" "0" \
        "strategy 1 PWM reset: "
    assert_system_files_removed
    printf '✓ Strategy 1 reset class-directory PWM and removed sandbox paths\n'
}

test_raw_device_pwm_reset() {
    prepare_case
    mkdir -p "$FAN_CONTROL_HWMON_BASE/hwmon0" "$SANDBOX/raw-device"
    ln -s "$SANDBOX/raw-device" "$FAN_CONTROL_HWMON_BASE/hwmon0/device"
    printf '191\n' >"$SANDBOX/raw-device/pwm1"

    run_uninstaller

    assert_eq "$(cat "$SANDBOX/raw-device/pwm1")" "0" \
        "strategy 2 PWM reset: "
    assert_system_files_removed
    printf '✓ Strategy 2 reset raw-device PWM and removed sandbox paths\n'
}

test_no_pwm_devices_warns_cleanly() {
    prepare_case
    mkdir -p "$FAN_CONTROL_HWMON_BASE/hwmon0"

    run_uninstaller

    assert_contains "$UNINSTALL_OUTPUT" "Warning: No PWM devices found to reset"
    assert_system_files_removed
    printf '✓ No-PWM fixture warned and completed cleanly\n'
}

case "${UNINSTALL_CASE:-all}" in
    all)
        test_class_directory_pwm_reset
        test_raw_device_pwm_reset
        test_no_pwm_devices_warns_cleanly
        ;;
    class)
        test_class_directory_pwm_reset
        ;;
    device)
        test_raw_device_pwm_reset
        ;;
    none)
        test_no_pwm_devices_warns_cleanly
        ;;
    *)
        fail "unknown UNINSTALL_CASE: ${UNINSTALL_CASE}"
        ;;
esac
