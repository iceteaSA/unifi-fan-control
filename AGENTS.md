# AGENTS.md

Adaptive fan controller for UniFi OS devices (UCG-Max, UCG-Fibre, UXG-Fibre, UDM-SE, UDM-Pro-Max, UDR7, UNVR). Pure bash — no build system or package manager.

## What this repo actually is

- `fan-control.sh` — the entire application: a single long-running bash daemon (config bootstrap → migration → validation → PWM auto-detection → state machine loop). All logic lives here.
- `install.sh` / `uninstall.sh` — run ON the UniFi device as root. `install.sh` uses complete local payloads first, then a checksum-verified pinned release (`FAN_CONTROL_VERSION`), an unverified branch (`FAN_CONTROL_BRANCH`), or the latest checksum-verified release. Tagged releases (`vX.Y.Z`) are the production identity.
- `fan-control.service` — systemd unit installed to `/etc/systemd/system/`; runs `/data/fan-control/fan-control.sh` as root.
- `VERSION` — repository release identity, stored as bare SemVer and logged at daemon startup.
- Runtime state on device: `/data/fan-control/{config,temp_state,optimal_pwm}` plus `/var/run/fan-control.pid`.

## Verification

The four local gates matching CI are:

```bash
bash -n fan-control.sh install.sh uninstall.sh tests/*.sh tests/lib/*.sh
bash tests/run-tests.sh
shellcheck fan-control.sh install.sh uninstall.sh tests/*.sh tests/lib/*.sh
shfmt -i 4 -ci -d fan-control.sh install.sh uninstall.sh tests/*.sh tests/lib/*.sh
```

The sandboxed suite needs no device or root; it uses `FAN_CONTROL_*` env seams to override device paths (`grep -ohE 'FAN_CONTROL_[A-Z_]+' *.sh | sort -u` for the current list). CI tests Bash 4.4, 5.1, 5.2, and native Ubuntu under mawk. ShellCheck and shfmt are both hard-zero — there is no baseline any more.

**Match CI's tool versions or the gates lie.** CI pins `shellcheck v0.11.0` and `shfmt v3.13.1` (see `.github/workflows/ci.yml`). Older ShellCheck emits findings 0.11 dropped — an apt-installed runner once failed on SC2002 that a local 0.11 run passed cleanly, so a green local gate meant nothing. Check with `shellcheck --version` before trusting a local pass.
- Nothing here runs on a dev machine: the script hard-requires `ubnt-systool` (UniFi-only) and writable `/sys/class/hwmon/*/pwm*`. Real testing means deploying to a device and watching `journalctl -u fan-control.service -f`. CONTRIBUTING.md lists the manual test scenarios (cold start, hot start, state transitions, sensor failure).
- To test a branch on a device: `sudo FAN_CONTROL_BRANCH=<branch> ./install.sh`. Branch installs are unverified; use a release pin for a checksum-verified deployment.

## Hard-earned constraints (from CONTRIBUTING.md + code)

- **Never remove config parameters.** The script self-heals configs: `check_param` appends missing keys, `validate_config` clamps bad values, and `migrate_config` rewrites old configs idempotently. New parameters need a `DEFAULT_*`, a `check_param` line, a `validate_config` line (if numeric), AND entries in all three heredoc config-rewrite blocks (initial create, corrected-values rewrite, migration rewrite) — they duplicate the full parameter list and drift silently if you miss one.
- All writes to config/state files must go through the atomic tmp-file + `mv` pattern (`atomic_write_file`).
- Fans must never be left in an undefined state: the EXIT trap and `uninstall.sh` both reset PWM to 0. Preserve this on any shutdown-path change.
- PWM detection has two strategies for a reason: hwmon class dirs (UCG-Max, UNVR) then raw `device/` symlink paths (UDM-SE, whose adt7475 driver exposes no class-level pwm files). Sysfs permissions lie — writability is proven by writing the current value back, not by `test -w`.
- Logging goes to syslog via `logger -t fan-control` with `PREFIX:` tags — ALERT, COLDSTART, CONFIG, DEADBAND, DETECT, DRIVE, ERROR, FATAL, FIXED, INIT, LEARNING, MIGRATE, SET, START, STATE, STATUS, TAPER, WARNING. Keep the pattern; TROUBLESHOOTING.md and users grep on those tags.
- **The unit caps logging at 10000 lines/day (`LogRateLimitBurst`, 24h rolling window).** The daemon once emitted ~19200/day and went silent by midday, taking every startup diagnostic with it on any afternoon restart. `TEMP:`/`CALC:`/`DEADBAND:` therefore log on a ≥2 °C change against the last *logged* value, not per cycle — comparing against the *previous* value is not enough, because a device oscillating 66/67 °C defeats it (45% of readings differ from their predecessor). Anything added to the per-cycle path must be counted against that cap at `CHECK_INTERVAL=5`, not at the default 15.
- Bash-only arithmetic (integer) except where `awk` is deliberately used for float smoothing — don't "simplify" the awk calls back to integer math; that caused drift before (see git history).
- **Never cache a one-shot reading of a mechanism with settling time.** This shipped twice. Drive detection excluded a drive unreadable at one instant for the whole process lifetime; fan detection read RPM *before* commanding any PWM, so after a restart it sampled what the EXIT trap left behind (fans at 0) and could drop a channel permanently — non-deterministically, since it depended on which fan was still coasting. Measured spin-up: ~1 s to register RPM, ~6 s to settle. Both paths now probe first, treat an absent reading as *unknown* rather than *absent*, and re-check periodically. A sensor read that decides something permanent is the bug.
- Drive temperature is an independent PWM **floor**, not an input to `calculate_speed` — the CPU curve is calibrated 65-85 °C and an SSD idling at 47 °C would be inert there. It is applied *after* `set_fan_speed`'s `STATE_OFF` override (it is the only thing allowed to lift PWM out of OFF), takes the hottest of all readable drives, and survives one drive failing. `nvme smart-log -o json` reports **kelvin**; `smartctl -j -A` reports **celsius** under the same field name — inverting that pins the fan to max forever.

## Device toolchain (measured, not assumed)

Measured on a UCG-Max: **bash 5.1.4 · GNU tar 1.34 (`/bin/tar`) · jq 1.6 · curl 7.74.0 · mawk 1.3.4 · smartctl 7.2 · systemd 247 · Debian 11 bullseye · aarch64 · busybox 1.30.1 present but not `tar`**. A UNVR reportedly matches on bash/jq/curl/Debian/arch; its `tar` has not been checked directly.

**UniFi OS is Debian, not Alpine Linux — and the confusion has a specific cause.** UDM-SE and UNVR kernel strings read `aarch64-linux-4.19.152-ui-alpine` / `-alpine-unvr`, which is the **Annapurna Labs Alpine AL-324 SoC**, not the distro. (The UCG-Max is Qualcomm IPQ5332 and carries no such string.) That homophone produced a documented-but-false claim in this repo that BusyBox tar strips leading `/` and `../` on device. It does not: `tar` is GNU 1.34, which **preserves** traversal paths and correctly flags hardlinks. The stripping and hardlink-misreporting belong to BusyBox tar in the **Alpine CI containers** — a different parser from the one on the install path, so CI-observed tar behaviour says nothing about the device. Run `--version` on the device before building on any belief about what it ships.

`install.sh` validates raw tar headers *after* verifying SHA256, so that parser only ever sees an archive matching a published checksum. Worth knowing before extending it: the threat it addresses requires an attacker who already controls the release, and who would edit `install.sh` itself — which `curl | sudo bash` fetches unverified.

## Conventions

- Commits: conventional-commit style (`feat:`, `fix:`, `docs:`, `refactor:`), imperative, ≤72-char subject. Branches: `feature/`, `fix/`, `docs/`, `refactor/`, `ci/` prefixes.
- Docs that must stay in sync with code changes: README.md (config table, features), TROUBLESHOOTING.md (known issues), CHANGELOG.md (Keep a Changelog format).
- PRs use `.github/PULL_REQUEST_TEMPLATE.md`.
