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

cleanup_sandbox
setup_sandbox

echo "66" >"$SANDBOX/cputemp"
start_daemon
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0

# A 1°C flutter is routine hardware noise; a sustained 2°C step is not.
/bin/sleep 1
before_tag_lines=$(grep -E -c ' (TEMP|CALC|DEADBAND):' "$SANDBOX/syslog" || true)

for ((iteration = 0; iteration < 30; iteration++)); do
    if ((iteration % 2 == 0)); then
        echo "67" >"$SANDBOX/cputemp"
    else
        echo "66" >"$SANDBOX/cputemp"
    fi
    /bin/sleep 0.08
done

after_tag_lines=$(grep -E -c ' (TEMP|CALC|DEADBAND):' "$SANDBOX/syslog" || true)
flutter_lines=$((after_tag_lines - before_tag_lines))

if ((flutter_lines > 6)); then
    fail "1°C flutter emitted ${flutter_lines} TEMP/CALC/DEADBAND lines in 30 cycles; expected at most 6"
fi

for temp in 68 70 72; do
    echo "$temp" >"$SANDBOX/cputemp"
    /bin/sleep 0.1
    wait_for_log "TEMP:  RAW=${temp}°C" 2
done

echo "  ✓ 1°C flutter emitted ${flutter_lines} tagged lines; 66→72 trend remained visible"
