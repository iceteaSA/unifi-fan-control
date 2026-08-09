#!/bin/bash
###############################################################################
# Regression test for GH #18: smoothing lost in command substitution.
#
# Bug: get_smoothed_temp called via $(...), so SMOOTHED_TEMP mutations were
# lost. Each call smoothed from the boot-time value (50) — smoothing never
# accumulated, and the logged SMOOTH value stayed constant.
#
# This test verifies the fix: SMOOTHED_TEMP is updated as a global and
# successive TEMP: log lines show strictly increasing smoothed values
# after a raw-temperature jump.
#
# Red check: the test MUST fail against a mutant that restores $(...)
# call sites, because SMOOTH stays frozen at 50.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

setup_sandbox

# Start at 50°C — the initial smoothed temp
echo "50" > "$SANDBOX/cputemp"

start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

# Let the daemon stabilise at 50°C (SMOOTH should converge to ~50)
/bin/sleep 2

# ── Clear syslog so only POST-jump TEMP lines are visible ──────────────────
: > "$SANDBOX/syslog"

# Now jump raw temperature to 70°C
echo "70" > "$SANDBOX/cputemp"

# Wait for smoothing to accumulate toward 70
/bin/sleep 3

# Collect SMOOTH values from TEMP: log lines — all of these are POST-jump.
# Format: "TEMP:  RAW=70°C | SMOOTH=66°C | DELTA=-4°C"
smoothed_values=$(sed -n 's/.*SMOOTH=\([0-9][0-9]*\).*/\1/p' "$SANDBOX/syslog" 2>/dev/null || true)

if [[ -z "$smoothed_values" ]]; then
    echo "--- syslog ---" >&2
    cat "$SANDBOX/syslog" >&2
    fail "No SMOOTH values logged after temperature jump"
fi

# With ALPHA=20 and raw=70 starting from smoothed≈50:
#   iter 1: (20*50 + 80*70)/100 = 66
#   iter 2: (20*66 + 80*70)/100 = 69
#   iter 3: (20*69 + 80*70)/100 = 69.8 → 70
# Regression (subshell loss): every call uses original SMOOTHED_TEMP=50,
# so SMOOTH stays at 66 forever (it recalculates (20*50 + 80*70)/100 = 66
# each time, but smoothed is never overwritten in the parent).

echo "  SMOOTH temperature values logged after jump:"
prev=""
increases=0
while IFS= read -r val; do
    printf "    %s" "$val"
    if [[ -n "$prev" ]]; then
        if (( val > prev )); then
            printf " ↑"
            increases=$((increases + 1))
        elif (( val == prev )); then
            printf " —"
        else
            printf " ↓"
        fi
    fi
    printf "\n"
    prev=$val
done <<<"$smoothed_values"

# Require at least 2 strictly increasing steps
if (( increases < 2 )); then
    fail "SMOOTH values should strictly increase toward raw temp (got ${increases} increasing steps). Regression: subshell loss would freeze smoothing at a single value."
fi

# The final SMOOTH value should be close to the raw temp (70)
last_val=$(tail -1 <<<"$smoothed_values")
if (( last_val < 66 )); then
    fail "Final SMOOTH value (${last_val}) should be ≥66. Regression: subshell loss froze smoothing at boot value."
fi

echo "  ✓ SMOOTH values increase toward raw temp (${increases} increasing steps, final=${last_val})"

stop_daemon
cleanup_sandbox

echo "  All smoothing regression tests (GH #18) passed."
