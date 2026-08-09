#!/bin/bash
###############################################################################
# PWM detection tests
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

# ── Scenario 1: single spinning fan remains controlled ───────────────────────
scenario=$((scenario + 1))
setup_sandbox

echo "70" >"$SANDBOX/cputemp"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0

assert_contains "$(cat "$SANDBOX/syslog")" "fan1" "should detect fan by name"

echo "  ✓ Scenario ${scenario}: Single spinning fan remains controlled"

stop_daemon
cleanup_sandbox

# ── Scenario 2: all stopped fans remain controlled ───────────────────────────
scenario=$((scenario + 1))
setup_sandbox

echo 0 >"$SANDBOX/hwmon/hwmon0/pwm2"
echo 0 >"$SANDBOX/hwmon/hwmon0/fan1_input"
echo 0 >"$SANDBOX/hwmon/hwmon0/fan2_input"
echo "70" >"$SANDBOX/cputemp"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm2" 0

assert_contains "$(cat "$SANDBOX/syslog")" "fan1 = 0 RPM" "should report stopped fan as unknown"

echo "  ✓ Scenario ${scenario}: All stopped fans remain controlled"

stop_daemon
cleanup_sandbox

# ── Scenario 3: partial detection controls a stopped channel ─────────────────
scenario=$((scenario + 1))
setup_sandbox

echo 0 >"$SANDBOX/hwmon/hwmon0/pwm2"
echo 0 >"$SANDBOX/hwmon/hwmon0/fan2_input"
echo "70" >"$SANDBOX/cputemp"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm2" 0

echo "  ✓ Scenario ${scenario}: Partial detection controls stopped channel"

stop_daemon
cleanup_sandbox

# ── Scenario 4: excluded channel recovers without restart ────────────────────
scenario=$((scenario + 1))
setup_sandbox

mkdir "$SANDBOX/hwmon/hwmon0/pwm2"
echo 3000 >"$SANDBOX/hwmon/hwmon0/fan2_input"
echo "70" >"$SANDBOX/cputemp"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"
wait_for_log "pwm2.*unavailable, excluding"

rm -rf "$SANDBOX/hwmon/hwmon0/pwm2"
echo 0 >"$SANDBOX/hwmon/hwmon0/pwm2"
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm2" 0 2
wait_for_log "pwm2.*writable again, including" 2

exclusion_count=$(grep -c "pwm2.*unavailable, excluding" "$SANDBOX/syslog" || true)
assert_eq "$exclusion_count" "1" "should log the unchanged exclusion once"

echo "  ✓ Scenario ${scenario}: Excluded channel recovers without restart"

stop_daemon
cleanup_sandbox

# ── Scenario 5: non-writable PWM → daemon exits with FATAL ───────────────────
scenario=$((scenario + 1))
setup_sandbox

# Root can write mode-444 regular files, and root is the default user in the
# official Docker Bash images, so chmod alone cannot make a candidate unusable
# there. A directory still satisfies the [[ -e ]] candidate scan but fails the
# daemon's `cat` read, so the channel is rejected for every user.
#
# The two branches reach the same FATAL outcome by different guards: non-root
# fails the write-back probe ("not writable, skipping"), root fails the read
# that precedes it. Only the non-root path covers the write-back probe itself.
if ((EUID == 0)); then
    rm "$SANDBOX/hwmon/hwmon0/pwm1"
    mkdir "$SANDBOX/hwmon/hwmon0/pwm1"
else
    chmod 444 "$SANDBOX/hwmon/hwmon0/pwm1"
fi
echo "50" >"$SANDBOX/cputemp"

start_daemon
/bin/sleep 1

if daemon_alive; then
    fail "Daemon should have exited when no writable PWM found"
fi

assert_contains "$(cat "$SANDBOX/syslog")" "FATAL" "should log FATAL on detection failure"

echo "  ✓ Scenario ${scenario}: Non-writable PWM: daemon exits with FATAL"

stop_daemon 2>/dev/null || true
cleanup_sandbox

echo "  All ${scenario} PWM detection scenarios passed."
