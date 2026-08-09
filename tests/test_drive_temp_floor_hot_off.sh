#!/bin/bash
###############################################################################
# Drive temperature floor test: hot drive must lift PWM from the OFF state.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

setup_sandbox
echo "45" >"$SANDBOX/cputemp"
touch "$FAN_CONTROL_DRIVE_DEV_DIR/nvme0n1"
cat >"$SANDBOX/nvme_response" <<'JSON'
{"temperature":330,"wctemp":83}
JSON

start_daemon
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0 10 || fail "hot drive did not lift PWM from OFF"

echo "  ✓ Hot drive lifted PWM from OFF"
