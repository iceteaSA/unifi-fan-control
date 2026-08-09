#!/bin/bash
###############################################################################
# Regression test for GH #17: lock + cleanup trap registered in subshell.
#
# Bug: trap was inside a `( flock ... ) 200>file` subshell that exits immediately.
# Consequences:
#   (a) The trap fires at startup, zeroing fans + deleting PID file.
#   (b) The daemon parent shell has no exit trap → fans not reset on SIGTERM.
#   (c) Single-instance guard is defeated → second copy starts.
#
# This test verifies the fix: flock held in parent shell, cleanup on EXIT.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# ── 1. Single instance lock: PID file exists with daemon PID while running ───
setup_sandbox
trap teardown_sandbox EXIT

echo "50" > "$SANDBOX/cputemp"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive" "Daemon should be running"

# Regression: old bug deleted PID file at startup → assertion would fail
pid_file_valid || fail "PID file should exist and contain daemon PID"

echo "  ✓ PID file exists with correct daemon PID while running"

# ── 2. Second instance rejected ──────────────────────────────────────────────
# Start a second copy of the daemon — it should fail to acquire the lock
bash "$FAN_CONTROL_SCRIPT" &
second_pid=$!
/bin/sleep 0.5

# The second instance should have exited (flock -n failed)
if kill -0 "$second_pid" 2>/dev/null; then
    kill "$second_pid" 2>/dev/null || true
    fail "Second instance should NOT be running (lock not exclusive)"
fi

# The syslog should contain the ALERT message about another instance
assert_contains "$(cat "$SANDBOX/syslog")" "Another instance" "Should log 'Another instance' ALERT"

echo "  ✓ Second instance rejected by flock guard"

# ── 3. Cleanup on SIGTERM: fans reset to 0, PID file removed ─────────────────
# Verify the FIRST daemon is still running
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive" "First daemon should still be running"

# First, let the daemon enter ACTIVE so PWM is non-zero
echo "75" > "$SANDBOX/cputemp"
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0 10 || fail "PWM should be > 0 before SIGTERM"

# Now send SIGTERM
kill -TERM "$DAEMON_PID" 2>/dev/null || true
wait "$DAEMON_PID" 2>/dev/null || true
DAEMON_PID=""

# After SIGTERM, cleanup should have run:
#   - PWM should be 0
pwm_after=$(get_pwm)
assert_eq "$pwm_after" "0" "PWM should be 0 after SIGTERM cleanup, got $pwm_after"

#   - PID file should be removed
pid_file="${FAN_CONTROL_PID_FILE:-$SANDBOX/pid}"
if [[ -f "$pid_file" ]]; then
    fail "PID file should be removed after cleanup, but still exists: $(cat "$pid_file" 2>/dev/null || echo '<unreadable>')"
fi

echo "  ✓ SIGTERM cleanup: PWM=0, PID file removed"

teardown_sandbox

# shellcheck disable=SC2317
echo "  All lifecycle regression tests (GH #17) passed."
