# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

AGENTS.md (imported above) holds the verification gates, device facts and hard-earned constraints. This file adds what you need to navigate the code and tests.

## Running tests

```bash
bash tests/run-tests.sh                 # full suite; every tests/test_*.sh in its own subprocess
bash tests/test_state_machine.sh        # one test file; exit 0 = pass, FAIL: lines on stderr
FAN_CONTROL_SCRIPT=/path/to/other.sh bash tests/run-tests.sh   # run the suite against another daemon copy
```

Run `bash tests/test_install.sh` on its own for installer changes. It covers local, pinned, latest and branch installs, archive validation and rollback.

## How fan-control.sh is laid out

The daemon is a **top-level script, not a set of functions behind a `main`**. Sourcing it runs it, so tests can't unit-call functions. Execution order, top to bottom:

1. Config bootstrap: write the defaults heredoc (`<<-DEFAULTS`) if no config exists, then `source` it.
2. `check_param` appends missing keys → `migrate_config` (2nd heredoc, `<<-CONFIG`) → `validate_config` clamps → a corrected-values rewrite (3rd heredoc, `<<-CONFIG`) if anything was clamped.
3. Derived values: `FAN_ACTIVATION_TEMP = MIN_TEMP + HYSTERESIS`, `TAPER_DURATION = TAPER_MINS * 60`.
4. `ubnt-systool` presence check, `detect_pwm_devices` (or the fixed `FAN_PWM_DEVICE` when autodetect is off).
5. `flock` on the PID file (the single-instance guard), then the `cleanup` EXIT trap that zeroes every PWM channel.
6. Seed `SMOOTHED_TEMP` from `temp_state` if it's within 15 °C of raw. Load or repair `optimal_pwm`. Run `detect_drive_temperature`. COLDSTART into OFF or ACTIVE.
7. Main loop: `update_fan_state`, re-run PWM detection every `PWM_RECHECK_LOOPS` (10) iterations, log `STATUS:` every 10 iterations, `sleep $CHECK_INTERVAL`.

Each cycle is `update_fan_state` → `get_smoothed_temp` (EMA through awk) → `update_drive_temperature` → the state machine → `set_fan_speed`.

- **State machine** (`update_fan_state`): `OFF → ACTIVE` at ≥ `FAN_ACTIVATION_TEMP`. `ACTIVE → TAPER` at ≤ `MIN_TEMP`. `TAPER → ACTIVE` at ≥ activation + 2. `TAPER → OFF` after `TAPER_MINS`. Any state goes to `EMERGENCY` at ≥ `MAX_TEMP` and leaves it at ≤ `MAX_TEMP - HYSTERESIS`. After 3 consecutive sensor read failures, it writes `MAX_PWM` straight to the devices and returns early, **bypassing `set_fan_speed`**. That bypass exists because the OFF override there would force 0.
- **`set_fan_speed`** applies its steps in this order: emergency override → OFF forces 0 → ramp limit by `MAX_PWM_STEP` → clamp to `[MIN_PWM, MAX_PWM]` → drive-temperature floor (itself ramp-limited) → write every channel in `FAN_PWM_DEVICES` → learning. Learning runs at most every 30 min in ACTIVE and nudges the `optimal_pwm` file. The in-memory `OPTIMAL_PWM`, used on entry to ACTIVE, is read only at startup, so a learned value takes effect after the next restart.
- `calculate_speed` is a quadratic curve from `FAN_ACTIVATION_TEMP` (`MIN_PWM`) to `MAX_TEMP` (`MAX_PWM`), clamped at zero below activation (#26).
- `has_meaningful_temp_change` mutates caller state. Call it directly, never inside `$(...)`.

## How the test harness works

Tests are black-box: `tests/lib/harness.sh` runs the real daemon as a background process inside a `mktemp` sandbox and asserts on files.

- `setup_sandbox` exports the `FAN_CONTROL_*` path seams into `$SANDBOX` and builds a fake `hwmon/hwmon0/{pwm1,fan1_input,name}`. It prepends stub binaries to `PATH`:
  - `ubnt-systool` prints `$SANDBOX/cputemp`. Write `FAIL` to it, or delete it, to simulate a sensor failure.
  - `logger` appends to `$SANDBOX/syslog`.
  - `sleep` always sleeps 0.05 s, so loop iterations are fast.
  - `nvme`/`smartctl` serve fixtures from `$SANDBOX/{nvme,smartctl}_response[_<dev>]` and fail on `*_fail[_<dev>]` / `smartctl_standby_<dev>`.
- Drive tests put fake device nodes under `$SANDBOX/drives`.
- Test pattern: `setup_sandbox; trap teardown_sandbox EXIT; start_daemon`, then `wait_for_log`, `wait_for_file_value`/`wait_for_file_gt` on `hwmon0/pwm1`, and `assert_*`. Multi-scenario files call `cleanup_sandbox` between scenarios.
- **Log text is test API.** Tests grep the syslog for exact `PREFIX:` messages, so rewording a log line can break tests (and users' greps, see AGENTS.md).
- Inside tests, use `/bin/sleep` for real waits, because plain `sleep` hits the stub.

## Adding a config parameter

On top of the AGENTS.md checklist (`DEFAULT_*`, `check_param`, `validate_config`, all three heredocs), `tests/test_config_parity.sh` statically checks that every heredoc, `DEFAULT_*` and `check_param` lists the same set. It **hardcodes the count (19)**, so bump it there when you add one. Also update the README config table.

## Releases and the installer

- Release Please (`release-please-config.json`, `.github/workflows/release.yml`) generates `vX.Y.Z` tags, `VERSION` and the CHANGELOG release entries from conventional commits on `main`. The commit subject becomes the changelog line.
- The release tarball contains exactly `fan-control.sh uninstall.sh fan-control.service VERSION`. A new runtime file must be added to both `release.yml` and `PAYLOAD_FILES` / `payload_destination` in `install.sh`, or installs reject or drop it.
- `install.sh` has its own seams (`FAN_CONTROL_INSTALL_DIR`, `FAN_CONTROL_SERVICE_FILE`, `FAN_CONTROL_SYSTEMCTL`, `FAN_CONTROL_RELEASE_BASE_URL`, `FAN_CONTROL_ALLOW_CHOWN_FAILURE`). Every install stages the payload, validates it (`bash -n`, SemVer `VERSION`), swaps it in, restarts the service, and rolls back on failure.
