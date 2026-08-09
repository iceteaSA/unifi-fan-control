#!/bin/bash
###############################################################################
# Regression test: saved-temp bootstrap must compute the real |saved - raw|
# absolute difference before deciding whether to reuse the persisted smoothed
# temperature.
#
# Bug: fan-control.sh used `(( ${saved_temp#-} - ${raw_temp#-} < 15 ))` to
# guard against re-initialising to a stale saved temp. The `${var#-}` form
# only strips a leading minus from *each operand independently* — it does
# NOT compute |saved - raw|. So only the `saved > raw` direction was guarded;
# when `raw > saved` (hot boot with a stale low saved temp) the difference
# was negative, always < 15, and SMOOTHED_TEMP was re-initialised to the
# stale low value. The subsequent coldstart decision at line 774
# (`SMOOTHED_TEMP >= FAN_ACTIVATION_TEMP`) ran BEFORE the smoothing loop, so
# a hot restart could keep the fan OFF for one full CHECK_INTERVAL.
#
# This test reproduces the symptom: a hot boot (raw=70°C) with a stale low
# persisted temp (saved=40°C). The bogus guard accepts the 40°C initiation;
# the coldstart branch then logs "Fans off" instead of going ACTIVE. The
# fix computes the real absolute difference (|70-40|=30 > 15 → discard) and
# boots into ACTIVE.
#
# Red check: this test MUST fail against the unfixed line 447, because the
# daemon inits SMOOTHED_TEMP=40 and the coldstart branch sees
# 40 < FAN_ACTIVATION_TEMP (60+5=65) → "Fans off".
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

setup_sandbox

# Force a hot boot: raw temp held high throughout
echo "70" >"$SANDBOX/cputemp"

# Pre-seed the persisted temp_state with a stale LOW value that the buggy
# guard would wrongly accept (raw > saved by 30°C).
echo "40" >"$FAN_CONTROL_TEMP_STATE_FILE"

# Boot the daemon
start_daemon
assert_eq "$(daemon_alive && echo "alive" || echo "dead")" "alive"

# Give it time to bootstrap and log the coldstart decision
/bin/sleep 1

# With the fix: |40-70|=30 ≥ 15 → saved discarded, SMOOTHED_TEMP init to 70,
# and FAN_ACTIVATION_TEMP (60+5=65) ≤ 70 → coldstart goes ACTIVE.
# Without the fix: 40 - 70 = -30 < 15 → saved accepted, SMOOTHED_TEMP=40,
# 40 < 65 → coldstart logs "Fans off".
if ! grep -q "COLDSTART: Initial temp 70°C ≥ 65°C" "$SANDBOX/syslog"; then
    echo "--- syslog ---" >&2
    cat "$SANDBOX/syslog" >&2
    fail "Hot boot did not go ACTIVE with discarded stale saved temp"
fi

if grep -q "COLDSTART: Initial temp 40°C" "$SANDBOX/syslog"; then
    echo "--- syslog ---" >&2
    cat "$SANDBOX/syslog" >&2
    fail "Stale low saved temp (40°C) was wrongly accepted on hot boot (raw=70°C)"
fi

echo "  ✓ Hot boot (raw=70°C) discarded stale saved temp (40°C) and went ACTIVE"
echo "  ✓ INIT:COLDSTART correctly used real |saved - raw| absolute difference"

stop_daemon
cleanup_sandbox

echo "  All saved-temp bootstrap regression tests passed."
