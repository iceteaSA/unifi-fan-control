# Changelog

All notable changes to the UCG Max Fan Control project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.1](https://github.com/iceteaSA/unifi-fan-control/compare/v1.1.0...v1.1.1) (2026-08-09)


### Bug Fixes

* restrict install and config permissions ([d8c6f5d](https://github.com/iceteaSA/unifi-fan-control/commit/d8c6f5da2051a28d86f676e7de10859207b8a9ed))

## [1.1.0](https://github.com/iceteaSA/unifi-fan-control/compare/v1.0.0...v1.1.0) (2026-08-09)


### Features

* verify release downloads before installing ([#32](https://github.com/iceteaSA/unifi-fan-control/issues/32)) ([0cb6750](https://github.com/iceteaSA/unifi-fan-control/commit/0cb6750038881883af6ab102b652bb0b15de1a24))

## 1.0.0 (2026-08-09)

First tagged release. The code has been running on people's routers for months
— what's new is that it now has a version number, verified downloads, and a
test suite. Everything below is relative to installing from `main` before today.

### Four cooling bugs fixed

* **Fan sped up as the device cooled** ([#26](https://github.com/iceteaSA/unifi-fan-control/issues/26)) — `calculate_speed` squared a signed `temp_diff`, mirroring the response curve below the activation temperature. Between `MIN_TEMP` and `FAN_ACTIVATION_TEMP` the fan got *louder* as the router got cooler, and 60 °C produced the same PWM as 70 °C. A reporter measured 603 PWM writes in 21 hours on an idle UCG-Fiber.
* **Sensor fail-safe never fired** ([#18](https://github.com/iceteaSA/unifi-fan-control/issues/18)) — `get_smoothed_temp` was called through `$(...)`, so its failure counter and smoothed temperature died in the subshell. The 3-strike fail-safe that forces `MAX_PWM` on sensor failure was unreachable code, and temperature smoothing never accumulated.
* **Cleanup trap fired at startup** ([#17](https://github.com/iceteaSA/unifi-fan-control/issues/17)) — the trap and `flock` were registered inside a subshell that exited immediately, so the PID file was deleted at launch, exit cleanup never ran, and the single-instance guard did nothing.
* **Stale temperature reused on hot restart** ([#22](https://github.com/iceteaSA/unifi-fan-control/issues/22)) — the guard on the persisted temperature stripped the minus sign from each operand instead of computing `|saved - raw|`, so it only protected one direction. A hot boot with a stale low value kept the fan off for a full check interval.

### Verified installs

* Releases are tagged, and each one ships a tarball plus `SHA256SUMS`.
* `install.sh` downloads, verifies the checksum, validates every archive entry, and syntax-checks the scripts before anything is written to `/data`. Archive entries are checked by raw tar header, not just filename, so an archive carrying a symlink under a legitimate name is rejected.
* Pin a version with `FAN_CONTROL_VERSION=v1.0.0`; omit it to get the latest release.
* Previously the installer fetched loose files from `main`, and a 404 could be written to disk and executed as root, because `curl` was called without `-f`.

### Version identity

The daemon logs `CONFIG: fan-control vX.Y.Z starting`, and `VERSION` is installed alongside it. Previously there was no way to tell which build a device was running short of hashing the script against git history.

### Testing and CI

* 11 sandboxed tests that need no device and no root, including a regression test per bug above.
* CI runs them on bash 4.4, 5.1, 5.2 and native Ubuntu, all under mawk — matching the UCG-Max, which runs bash 5.1.4 and mawk 1.3.4.
* shellcheck and shfmt are enforced at zero findings.

## [Unreleased]

### Added
- Tagged release automation with verified runtime tarballs and `SHA256SUMS`.
- Verified release installation with latest-release resolution and
  `FAN_CONTROL_VERSION` pinning.
- Archive allowlist, checksum, syntax, and rollback validation before installer
  files replace the running deployment.
- `VERSION` identity file and startup logging for the deployed daemon version.
- Test suite (`tests/`) — sandboxed, no-root, dependency-free bash tests covering config bootstrap, PWM detection, state machine, and regression tests for #17 and #18.
- Env-var seams for testability: `FAN_CONTROL_CONFIG_FILE`, `FAN_CONTROL_TEMP_STATE_FILE`, `FAN_CONTROL_PID_FILE`, `FAN_CONTROL_OPTIMAL_PWM_FILE`, `FAN_CONTROL_HWMON_BASE`.
- CONTRIBUTING.md with contribution guidelines
- CHANGELOG.md for tracking version history
- TROUBLESHOOTING.md for common issues and solutions
- SECURITY.md for security policy
- CODE_OF_CONDUCT.md for community guidelines
- GitHub issue templates for bug reports and feature requests
- GitHub pull request template

### Fixed
- [#17](https://github.com/iceteaSA/unifi-fan-control/issues/17): Lock and cleanup trap were registered in a subshell that exited immediately. Moved `flock` and `trap` to the parent shell so the lock is held for the daemon's lifetime, cleanup runs on actual exit, and single-instance guard is authoritative.
- [#18](https://github.com/iceteaSA/unifi-fan-control/issues/18): `get_smoothed_temp` was called via `$(...)`, losing `TEMP_READ_FAILURES` and `SMOOTHED_TEMP` mutations in subshells. Rewrote to communicate via globals; added a sensor fail-safe in `update_fan_state` that forces `MAX_PWM` after 3 consecutive read failures, bypassing state-machine and ramp limits.
- Fan speed no longer increases as the device cools below the activation temperature; the quadratic curve now clamps sub-activation `temp_diff` to zero (#26).
- Saved-temp bootstrap used `(( ${saved_temp#-} - ${raw_temp#-} < 15 ))` to guard against re-initialising to a stale persisted smoothed temp. The `${var#-}` form strips a leading minus from *each operand independently* and does **not** compute `|saved - raw|`, so only the `saved > raw` direction was guarded. On a hot restart with a stale low saved temp (`raw > saved`), the difference was negative, always `< 15`, and `SMOOTHED_TEMP` was re-initialised to the stale low value — leaving the coldstart fan-OFF decision at line 774 to run against a too-low temp and keeping the fan OFF for one full `CHECK_INTERVAL`. Replaced with a real absolute difference; added `tests/test_regression_saved_temp_bootstrap.sh`.

## Recent Changes (Based on Git History)

### [2025-01-13] - Enhanced Reliability and Precision

#### Changed
- Removed locale settings and enhanced temperature smoothing precision
- Refactored temperature smoothing and PWM logic for better precision and reliability
- Improved error handling with atomic writes and logging

#### Fixed
- Ensured fan PWM is set to 0 during uninstallation to prevent unintended behavior

### Previous Features

#### Temperature Management
- Four operational states: OFF, TAPER, ACTIVE, EMERGENCY
- Quadratic response curve for progressive cooling
- Exponential smoothing for noise-resistant temperature tracking
- State transition hysteresis to prevent rapid oscillation

#### Safety Systems
- Emergency override for critical temperatures
- Speed limits and thermal protection
- Hardware validation on startup
- Sensor failure detection and recovery
- Configuration validation with automatic correction

#### Adaptive Learning
- Enhanced adaptive learning system
- Intelligent PWM optimization
- Temperature trend analysis
- Efficiency optimization strategies

#### Configuration
- User-configurable temperature thresholds
- Adjustable fan speed ranges
- Customizable smoothing factors
- Flexible check intervals and taper duration

#### Installation
- One-line installation command
- Support for branch-specific installations
- Smart service management (fresh install or hot update)
- Automatic configuration file creation with defaults

#### Monitoring
- Comprehensive logging system
- Real-time status updates
- Temperature delta tracking
- Learning activity logs
- Configuration change notifications

---

## Version History Format

Future releases will follow this format:

## [X.Y.Z] - YYYY-MM-DD

### Added
- New features

### Changed
- Changes in existing functionality

### Deprecated
- Soon-to-be removed features

### Removed
- Removed features

### Fixed
- Bug fixes

### Security
- Security improvements or fixes

---

**Note**: This changelog was created on 2025-11-13. Previous changes were reconstructed from git commit history and README documentation.
