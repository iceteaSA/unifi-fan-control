# AGENTS.md

Adaptive fan controller for UniFi OS devices (UCG-Max, UCG-Fibre, UXG-Fibre, UDM-SE, UDM-Pro-Max, UDR7, UNVR). Pure bash — no build system or package manager.

## What this repo actually is

- `fan-control.sh` — the entire application: a single long-running bash daemon (config bootstrap → migration → validation → PWM auto-detection → state machine loop). All logic lives here.
- `install.sh` / `uninstall.sh` — run ON the UniFi device as root. `install.sh` prefers local files next to itself, otherwise downloads from `raw.githubusercontent.com/iceteaSA/unifi-fan-control/$FAN_CONTROL_BRANCH` (default `main`). Pushing to `main` is effectively releasing — users install via `curl | sudo bash` from raw main.
- `fan-control.service` — systemd unit installed to `/etc/systemd/system/`; runs `/data/fan-control/fan-control.sh` as root.
- Runtime state on device: `/data/fan-control/{config,temp_state,optimal_pwm}` plus `/var/run/fan-control.pid`.

## Verification

The four local gates matching CI are:

```bash
bash -n fan-control.sh install.sh uninstall.sh tests/*.sh tests/lib/*.sh
bash tests/run-tests.sh
shellcheck fan-control.sh install.sh uninstall.sh tests/*.sh tests/lib/*.sh
shfmt -i 4 -ci -d fan-control.sh install.sh uninstall.sh tests/*.sh tests/lib/*.sh
```

The sandboxed suite has 9 tests after Phase 0 and needs no device or root; it uses `FAN_CONTROL_*` env seams to override device paths. CI tests Bash 4.4, 5.1, 5.2, and native Ubuntu under mawk. The ShellCheck baseline in `.github/shellcheck-baseline.tsv` is temporary debt until Phase 2, not permission to add new warnings.
- Nothing here runs on a dev machine: the script hard-requires `ubnt-systool` (UniFi-only) and writable `/sys/class/hwmon/*/pwm*`. Real testing means deploying to a device and watching `journalctl -u fan-control.service -f`. CONTRIBUTING.md lists the manual test scenarios (cold start, hot start, state transitions, sensor failure).
- To test a branch on a device: `sudo FAN_CONTROL_BRANCH=<branch> ./install.sh` (or the curl one-liner against that branch).

## Hard-earned constraints (from CONTRIBUTING.md + code)

- **Never remove config parameters.** The script self-heals configs: `check_param` appends missing keys, `validate_config` clamps bad values, and `migrate_config` rewrites old configs idempotently. New parameters need a `DEFAULT_*`, a `check_param` line, a `validate_config` line (if numeric), AND entries in all three heredoc config-rewrite blocks (initial create, corrected-values rewrite, migration rewrite) — they duplicate the full parameter list and drift silently if you miss one.
- All writes to config/state files must go through the atomic tmp-file + `mv` pattern (`atomic_write_file`).
- Fans must never be left in an undefined state: the EXIT trap and `uninstall.sh` both reset PWM to 0. Preserve this on any shutdown-path change.
- PWM detection has two strategies for a reason: hwmon class dirs (UCG-Max, UNVR) then raw `device/` symlink paths (UDM-SE, whose adt7475 driver exposes no class-level pwm files). Sysfs permissions lie — writability is proven by writing the current value back, not by `test -w`.
- Logging goes to syslog via `logger -t fan-control` with `PREFIX:` tags (CONFIG/DETECT/TEMP/CALC/SET/STATE/LEARNING/ERROR/FATAL). Keep the pattern; TROUBLESHOOTING.md and users grep on those tags.
- Bash-only arithmetic (integer) except where `awk` is deliberately used for float smoothing — don't "simplify" the awk calls back to integer math; that caused drift before (see git history).

## Conventions

- Commits: conventional-commit style (`feat:`, `fix:`, `docs:`, `refactor:`), imperative, ≤72-char subject. Branches: `feature/`, `fix/`, `docs/`, `refactor/` prefixes.
- Docs that must stay in sync with code changes: README.md (config table, features), TROUBLESHOOTING.md (known issues), CHANGELOG.md (Keep a Changelog format).
- PRs use `.github/PULL_REQUEST_TEMPLATE.md`.
