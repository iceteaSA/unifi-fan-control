# Changelog

All notable changes to the UCG Max Fan Control project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Tagged release automation with verified runtime tarballs and `SHA256SUMS`.
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
