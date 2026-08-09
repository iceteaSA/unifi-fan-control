#!/bin/bash
###############################################################################
# Steady-state logging tests
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

setup_sandbox

echo "70" >"$SANDBOX/cputemp"
start_daemon
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0

# The daemon has reached its stable active state before this sampling window.
/bin/sleep 1
before_lines=$(wc -l <"$SANDBOX/syslog")
/bin/sleep 1
after_lines=$(wc -l <"$SANDBOX/syslog")
steady_lines=$((after_lines - before_lines))

if ((steady_lines > 4)); then
    fail "stable temperature emitted ${steady_lines} lines in 20 cycles; expected at most 4"
fi

assert_contains "$(cat "$SANDBOX/syslog")" "CONFIG: fan-control" "should retain startup diagnostics"
assert_contains "$(cat "$SANDBOX/syslog")" "SET:" "should retain PWM changes"
assert_contains "$(cat "$SANDBOX/syslog")" "STATUS:" "should retain heartbeat"

echo "  ✓ Stable temperature emitted ${steady_lines} lines in 20 cycles"
