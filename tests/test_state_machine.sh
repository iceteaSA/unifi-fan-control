#!/bin/bash
###############################################################################
# State machine tests: OFF → ACTIVE → EMERGENCY → TAPER
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

# ── Scenario 1: below activation → stays OFF, PWM=0 ─────────────────────────
scenario=$((scenario + 1))
setup_sandbox

echo "45" >"$SANDBOX/cputemp"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

/bin/sleep 1
pwm=$(get_pwm)
assert_eq "$pwm" "0" "PWM should be 0 when below activation temp, got $pwm"

assert_contains "$(cat "$SANDBOX/syslog")" "OFF" "should reference OFF state in logs"

echo "  ✓ Scenario ${scenario}: OFF state: PWM=0 below activation threshold"

stop_daemon
cleanup_sandbox

# ── Scenario 2: above activation → OFF→ACTIVE transition, PWM > 0 ───────────
scenario=$((scenario + 1))
setup_sandbox

# Start cold so the daemon enters OFF via coldstart, then heat up to trigger transition
echo "45" >"$SANDBOX/cputemp"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

# Let daemon stabilise in OFF state
/bin/sleep 1

# Now heat up to trigger OFF→ACTIVE transition
echo "75" >"$SANDBOX/cputemp"

wait_for_log "OFF→ACTIVE" 15 || fail "OFF→ACTIVE transition not logged"
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0 10 || fail "PWM should be > 0 in ACTIVE state"

echo "  ✓ Scenario ${scenario}: OFF→ACTIVE: transition logged, PWM > 0"

stop_daemon
cleanup_sandbox

# ── Scenario 3: at/above MAX_TEMP → EMERGENCY, PWM=255 ──────────────────────
scenario=$((scenario + 1))
setup_sandbox

# Start warm so daemon is active, then spike to trigger EMERGENCY
echo "70" >"$SANDBOX/cputemp"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

# Let daemon enter ACTIVE state first
/bin/sleep 1

# Spike to 95°C to trigger EMERGENCY
echo "95" >"$SANDBOX/cputemp"

wait_for_log "→EMERGENCY" 15 || fail "EMERGENCY transition not logged"
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "255" 15 || fail "PWM should reach 255 in EMERGENCY"

echo "  ✓ Scenario ${scenario}: EMERGENCY: transition logged, PWM=255"

stop_daemon
cleanup_sandbox

# ── Scenario 4: cooling below MIN_TEMP → ACTIVE→TAPER transition ────────────
scenario=$((scenario + 1))
setup_sandbox

# Start cold and let daemon stabilise in OFF, then heat to ACTIVE before cooling
echo "45" >"$SANDBOX/cputemp"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

# Heat to ACTIVE
echo "70" >"$SANDBOX/cputemp"
wait_for_log "OFF→ACTIVE" 15 || fail "Should reach ACTIVE state from OFF"

# Now cool down below MIN_TEMP (60) to trigger ACTIVE→TAPER
echo "40" >"$SANDBOX/cputemp"

wait_for_log "ACTIVE→TAPER" 15 || fail "ACTIVE→TAPER transition not logged"

echo "  ✓ Scenario ${scenario}: ACTIVE→TAPER: transition logged on cooldown"

stop_daemon
cleanup_sandbox

echo "  All ${scenario} state machine scenarios passed."
