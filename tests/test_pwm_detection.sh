#!/bin/bash
###############################################################################
# PWM detection tests
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

# ── Scenario 1: class-dir strategy finds fan with RPM > 0 ────────────────────
scenario=$((scenario + 1))
setup_sandbox

echo "50" > "$SANDBOX/cputemp"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

assert_contains "$(cat "$SANDBOX/syslog")" "fan1" "should detect fan by name"

echo "  ✓ Scenario ${scenario}: Class-dir detection: fan found"

stop_daemon
cleanup_sandbox

# ── Scenario 2: fallback to all-writable when no fan is spinning ─────────────
scenario=$((scenario + 1))
setup_sandbox

echo 0 > "$SANDBOX/hwmon/hwmon0/fan1_input"
echo "50" > "$SANDBOX/cputemp"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

assert_contains "$(cat "$SANDBOX/syslog")" "using all writable" "should fall back to all writable"

echo "  ✓ Scenario ${scenario}: Fallback: all-writable used when no fan spinning"

stop_daemon
cleanup_sandbox

# ── Scenario 3: non-writable PWM → daemon exits with FATAL ───────────────────
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
if (( EUID == 0 )); then
    rm "$SANDBOX/hwmon/hwmon0/pwm1"
    mkdir "$SANDBOX/hwmon/hwmon0/pwm1"
else
    chmod 444 "$SANDBOX/hwmon/hwmon0/pwm1"
fi
echo "50" > "$SANDBOX/cputemp"

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
