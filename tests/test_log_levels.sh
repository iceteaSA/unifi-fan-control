#!/bin/bash
###############################################################################
# LOG_LEVEL filtering and the per-cycle DEADBAND threshold line
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

# ── Scenario 1: default info level drops per-cycle diagnostics ──────────────
scenario=$((scenario + 1))
setup_sandbox

echo "70" >"$SANDBOX/cputemp"
start_daemon
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0
wait_for_log "STATUS:" 5

syslog=$(cat "$SANDBOX/syslog")
assert_eq "$(grep "^LOG_LEVEL=" "$SANDBOX/config" | cut -d= -f2 | awk '{print $1}')" "info" "default LOG_LEVEL: "
if grep -qE ' (TEMP|CALC|DEADBAND):' <<<"$syslog"; then
    fail "info level emitted debug lines"
fi
assert_contains "$syslog" "daemon.info SET:" "info lines carry their priority: "
echo "  ✓ Scenario ${scenario}: info level suppresses TEMP/CALC/DEADBAND"

stop_daemon
cleanup_sandbox

# ── Scenario 2: error level keeps errors, drops everything else ─────────────
scenario=$((scenario + 1))
setup_sandbox

set_config LOG_LEVEL=error
echo "70" >"$SANDBOX/cputemp"
start_daemon
echo "FAIL" >"$SANDBOX/cputemp"
wait_for_log "ERROR: Failed to read temperature" 5

syslog=$(cat "$SANDBOX/syslog")
assert_contains "$syslog" "daemon.err ERROR:" "errors carry err priority: "
if grep -qE ' (CONFIG|START|STATUS|SET|ALERT):' <<<"$syslog"; then
    fail "error level emitted non-error lines"
fi
echo "  ✓ Scenario ${scenario}: error level emits only errors"

stop_daemon
cleanup_sandbox

# ── Scenario 3: invalid level falls back to info and is rewritten ───────────
scenario=$((scenario + 1))
setup_sandbox

set_config LOG_LEVEL=verbose
start_daemon
wait_for_log "CONFIG: Invalid LOG_LEVEL value: verbose, using default: info" 5
assert_eq "$(grep "^LOG_LEVEL=" "$SANDBOX/config" | cut -d= -f2 | awk '{print $1}')" "info" "corrected LOG_LEVEL: "
echo "  ✓ Scenario ${scenario}: invalid LOG_LEVEL corrected to info"

stop_daemon
cleanup_sandbox

# ── Scenario 4: DEADBAND threshold line is not repeated every cycle ─────────
# Between MIN_TEMP (60) and activation (65) the speed is pinned at MIN_PWM, so
# no PWM write happens and LAST_AVG_TEMP never catches up; the delta persists.
scenario=$((scenario + 1))
setup_sandbox

set_config LOG_LEVEL=debug DEADBAND=0
echo "70" >"$SANDBOX/cputemp"
start_daemon
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 91
echo "62" >"$SANDBOX/cputemp"
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "91" 5

# Let smoothing settle, then sample ~20 cycles at a constant temperature.
/bin/sleep 1
before=$(grep -c 'DEADBAND:  DELTA=.*THRESHOLD' "$SANDBOX/syslog" || true)
/bin/sleep 1
after=$(grep -c 'DEADBAND:  DELTA=.*THRESHOLD' "$SANDBOX/syslog" || true)

if ((after - before > 0)); then
    fail "constant temperature emitted $((after - before)) DEADBAND threshold lines; expected 0"
fi
((after > 0)) || fail "DEADBAND threshold line should be logged once when first crossed"
echo "  ✓ Scenario ${scenario}: DEADBAND threshold logged once, not per cycle"

stop_daemon
cleanup_sandbox

echo "  All ${scenario} log level scenarios passed."
