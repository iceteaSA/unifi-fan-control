#!/usr/bin/env bash
###############################################################################
# Startup version identity tests.
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

setup_sandbox
printf '%s\n' '1.2.3' >"$FAN_CONTROL_VERSION_FILE"
start_daemon
wait_for_log 'CONFIG: fan-control v1.2.3 starting' 10 || fail 'valid version was not logged'
assert_eq "$(daemon_alive && echo alive || echo dead)" 'alive' 'daemon should remain alive'
echo '  ✓ Valid VERSION logs the deployed SemVer'
stop_daemon
cleanup_sandbox

setup_sandbox
printf '%s\n' '0.9.0-rc1' >"$FAN_CONTROL_VERSION_FILE"
start_daemon
wait_for_log 'CONFIG: fan-control v0.9.0-rc1 starting' 10 || fail 'prerelease version was not logged verbatim'
echo '  ✓ Prerelease VERSION logs verbatim, not as unknown'
stop_daemon
cleanup_sandbox

setup_sandbox
printf '%s\n' 'not-a-version' >"$FAN_CONTROL_VERSION_FILE"
start_daemon
wait_for_log 'CONFIG: fan-control vunknown starting' 10 || fail 'malformed VERSION was not logged as unknown'
echo '  ✓ Malformed VERSION degrades to unknown'
stop_daemon
cleanup_sandbox

setup_sandbox
echo '70' >"$SANDBOX/cputemp"
start_daemon
wait_for_log 'CONFIG: fan-control vunknown starting' 10 || fail 'missing VERSION was not logged as unknown'
assert_eq "$(daemon_alive && echo alive || echo dead)" 'alive' 'daemon should remain alive without VERSION'
wait_for_file_gt "$SANDBOX/hwmon/hwmon0/pwm1" 0 10 || fail 'daemon should keep cooling without VERSION'
echo '  ✓ Missing VERSION logs unknown and keeps cooling'
