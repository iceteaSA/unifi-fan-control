# Troubleshooting Guide

This guide covers common issues and their solutions for the UniFi Fan Control system.

## Table of Contents

- [Service Issues](#service-issues)
- [Fan Behavior Issues](#fan-behavior-issues)
- [Temperature Monitoring Issues](#temperature-monitoring-issues)
- [Configuration Issues](#configuration-issues)
- [Installation Issues](#installation-issues)
- [Performance Issues](#performance-issues)
- [Diagnostic Commands](#diagnostic-commands)
- [Hardware Compatibility Notes](#hardware-compatibility-notes)

---

## Service Issues

### Service Won't Start

**Symptoms**: Service fails to start or immediately stops

**Check service status**:
```bash
systemctl status fan-control.service
journalctl -u fan-control.service -n 50
```

**Common causes**:

1. **Missing dependencies**:
   ```bash
   # Check if ubnt-systool is available
   which ubnt-systool

   # Test temperature reading
   ubnt-systool cputemp
   ```

2. **PWM device not accessible**:
   ```bash
   # Check if PWM device exists and is writable
   ls -la /sys/class/hwmon/hwmon0/pwm1

   # If device path is different, update config
   find /sys/class/hwmon -name "pwm*"
   ```

3. **Another instance running**:
   ```bash
   # Check for existing process
   ps aux | grep fan-control

   # Remove stale PID file if needed
   sudo rm -f /var/run/fan-control.pid
   ```

4. **Permission issues**:
   ```bash
   # Verify service file permissions
   ls -la /etc/systemd/system/fan-control.service

   # Verify script permissions
   ls -la /data/fan-control/fan-control.sh
   ```

### Service Keeps Restarting

**Symptoms**: Service continuously crashes and restarts

**Check logs for errors**:
```bash
journalctl -u fan-control.service -f
```

**Common causes**:

1. **Configuration errors**: Check for invalid config values
2. **Hardware issues**: PWM device becoming unavailable
3. **Temperature sensor failures**: Multiple consecutive read failures

**Solutions**:
```bash
# Reset configuration to defaults
sudo rm /data/fan-control/config
sudo systemctl restart fan-control.service

# Verify hardware access
cat /sys/class/hwmon/hwmon0/pwm1
```

---

## Fan Behavior Issues

### Fan Always Runs at Full Speed

**Symptoms**: Fan always at 255 PWM regardless of temperature

**Possible causes**:

1. **Emergency mode triggered**: Temperature at or above MAX_TEMP
   ```bash
   # Check current temperature
   ubnt-systool cputemp

   # Check MAX_TEMP setting
   grep MAX_TEMP /data/fan-control/config
   ```

2. **Sensor failure safety mode**: Multiple temperature read failures
   ```bash
   # Check for temperature reading errors
   journalctl -u fan-control.service | grep "ERROR.*temperature"
   ```

**Solutions**:
```bash
# Wait for temperature to drop below MAX_TEMP - HYSTERESIS
# Default: 85°C - 5°C = 80°C

# Or adjust MAX_TEMP if needed
sudo nano /data/fan-control/config
# Increase MAX_TEMP (default: 85)
sudo systemctl restart fan-control.service
```

### Fan Never Turns On

**Symptoms**: Fan stays off even when temperature rises

**Check**:
```bash
# Current temperature
ubnt-systool cputemp

# Activation threshold
grep -E "MIN_TEMP|HYSTERESIS" /data/fan-control/config

# Calculate activation temperature: MIN_TEMP + HYSTERESIS
# Default: 60°C + 5°C = 65°C
```

**Possible causes**:

1. **Temperature below activation threshold**
2. **PWM not being written to device**
3. **Service not running**

**Solutions**:
```bash
# Lower activation temperature
sudo nano /data/fan-control/config
# Decrease MIN_TEMP or HYSTERESIS
sudo systemctl restart fan-control.service

# Test manual PWM control
echo 100 | sudo tee /sys/class/hwmon/hwmon0/pwm1
```

### Fan Oscillates/Rapid Changes

**Symptoms**: Fan speed changes rapidly or oscillates

**This indicates**:
- Temperature near threshold boundaries
- Insufficient hysteresis
- Deadband too small

**Solutions**:
```bash
sudo nano /data/fan-control/config

# Increase HYSTERESIS (prevents rapid state changes)
HYSTERESIS=7  # Default: 5

# Increase DEADBAND (prevents small PWM adjustments)
DEADBAND=2    # Default: 1

# Increase ALPHA (slower temperature response)
ALPHA=30      # Default: 20 (higher = more smoothing)

sudo systemctl restart fan-control.service
```

### Fan Runs Too Loud

**Symptoms**: Fan noise is excessive

**Solutions**:
```bash
sudo nano /data/fan-control/config

# Increase smoothing for less aggressive response
ALPHA=30      # Default: 20 (higher = more smoothing)

# Reduce maximum speed
MAX_PWM=200   # Default: 255

# Increase minimum temperature threshold
MIN_TEMP=65   # Default: 60

# Reduce learning rate for less aggressive optimization
LEARNING_RATE=3  # Default: 5

sudo systemctl restart fan-control.service
```

### Fan Spins Too Slowly / Temperature Too High

**Symptoms**: Device running warmer than desired

**Solutions**:
```bash
sudo nano /data/fan-control/config

# Lower temperature thresholds
MIN_TEMP=55   # Default: 60

# Increase minimum fan speed
MIN_PWM=100   # Default: 91

# Reduce smoothing for faster response
ALPHA=15      # Default: 20 (lower = faster response)

# Reset optimal PWM to start fresh
sudo rm /data/fan-control/optimal_pwm

sudo systemctl restart fan-control.service
```

---

## Temperature Monitoring Issues

### Temperature Readings Seem Incorrect

**Symptoms**: Temperature values don't match expectations

**Verify temperature reading**:
```bash
# Direct reading
ubnt-systool cputemp

# Check smoothed vs raw in logs
journalctl -u fan-control.service -n 20 | grep "TEMP:"
```

**Common causes**:

1. **Smoothing effect**: System uses exponential smoothing
   - SMOOTHED temp lags behind RAW temp by design
   - Adjust ALPHA to change smoothing behavior

2. **Temperature sensor location**: CPU temp may differ from case temp

**Solutions**:
```bash
# For faster temperature response
sudo nano /data/fan-control/config
ALPHA=10  # Lower values = faster response to changes

sudo systemctl restart fan-control.service
```

### Multiple Temperature Read Failures

**Symptoms**: Logs show "ERROR: Failed to read temperature"

**Check**:
```bash
# Test temperature sensor
ubnt-systool cputemp

# Check for system issues
journalctl -xe
```

**Solutions**:
- System issue: Reboot device
- Persistent failures: Hardware problem, contact Ubiquiti support

**Safety behavior**: After 3 consecutive failures, system activates fans as safety measure

---

### Drive Temperature Floor Is Active

**Symptoms**: The fan runs while CPU temperature is below its activation threshold, or `DRIVE:` appears in the log.

The drive floor is separate from the CPU curve. It starts at 50°C and reaches maximum PWM at 70°C by default. A device without a readable drive stays silent and keeps the existing CPU-only behavior.

**Check**:
```bash
journalctl -u fan-control.service -n 50 | grep "DRIVE:"
```

**Tune or disable it**:
```bash
sudo nano /data/fan-control/config

DRIVE_MIN_TEMP=55        # Start the floor later
DRIVE_MAX_TEMP=75        # Reach maximum PWM later
# DRIVE_TEMP_ENABLED=false  # Skip drive detection entirely

sudo systemctl restart fan-control.service
```

---
## Configuration Issues

### Configuration Changes Not Applied

**Symptoms**: Changes to config file don't take effect

**Solution**:
```bash
# Always restart service after config changes
sudo systemctl restart fan-control.service

# Verify service restarted successfully
systemctl status fan-control.service
```

### Invalid Configuration Values

**Symptoms**: Logs show "CONFIG: Invalid value" messages

**The system**:
- Automatically detects invalid values
- Uses defaults for invalid parameters
- Updates config file with corrected values

**Check corrected values**:
```bash
journalctl -u fan-control.service | grep "CONFIG:"
cat /data/fan-control/config
```

**Valid ranges**:
- MIN_PWM: 0-255
- MAX_PWM: MIN_PWM-255
- MIN_TEMP: 30-80°C
- MAX_TEMP: MIN_TEMP-100°C
- HYSTERESIS: 1-15°C
- CHECK_INTERVAL: 5-60 seconds
- TAPER_MINS: 1-240 minutes
- MAX_PWM_STEP: 1-50
- DEADBAND: 0-10°C
- ALPHA: 1-99
- LEARNING_RATE: 1-20

### Missing Configuration Parameters

**Symptoms**: Logs show "CONFIG: Missing parameter detected"

**The system**:
- Automatically detects missing parameters
- Adds them with default values
- Updates config file

**No action needed** - system handles this automatically

---

## Installation Issues

### Installation Fails

**Common issues**:

1. **Not running as root**:
   ```bash
   # Use sudo
   sudo ./install.sh
   ```

2. **Missing dependencies**:
   ```bash
   # Check for required commands
   which systemctl
   which curl
   ```

3. **Directory not writable**:
   ```bash
   # Check permissions
   ls -la /data

   # May need to create /data if it doesn't exist (unusual)
    sudo mkdir -p /data
    ```

### Release Download or Checksum Failure

The default installer uses the latest tagged release. To retry a known release:

```bash
curl -fsSL https://raw.githubusercontent.com/iceteaSA/unifi-fan-control/main/install.sh | sudo FAN_CONTROL_VERSION=v1.2.0 bash
```

The installer verifies the downloaded tarball against the matching
`SHA256SUMS`. A checksum or archive validation failure leaves the installed
files unchanged. Check the installed identity with:

```bash
cat /data/fan-control/VERSION
```

### Branch-Specific Installation Fails

**Issue**: Can't install from a specific branch

Branch installs are for development only and are not checksum-verified.

```bash
curl -fsSL https://raw.githubusercontent.com/iceteaSA/unifi-fan-control/main/install.sh | sudo FAN_CONTROL_BRANCH=feature/example bash

# Or install local runtime files from a checkout
git clone https://github.com/iceteaSA/unifi-fan-control.git
cd unifi-fan-control
sudo ./install.sh
```

---

## Performance Issues

### High CPU Usage

**Normal behavior**: Script is very lightweight

**If experiencing high CPU usage**:
```bash
# Check if multiple instances running
ps aux | grep fan-control.sh

# Kill extra instances
sudo systemctl stop fan-control.service
sudo rm -f /var/run/fan-control.pid
sudo systemctl start fan-control.service
```

### Excessive Logging

**Symptoms**: Too many log messages

**Check log volume**:
```bash
journalctl -u fan-control.service --since "1 hour ago" | wc -l
```

**Note**: Service has built-in rate limiting (10,000 logs/day)

**Solutions**:
```bash
# Increase check interval to reduce logging frequency
sudo nano /data/fan-control/config
CHECK_INTERVAL=30  # Default: 15 seconds

sudo systemctl restart fan-control.service
```

---

## Diagnostic Commands

### Essential Checks

```bash
# Service status
systemctl status fan-control.service

# Live log monitoring
journalctl -u fan-control.service -f

# Recent logs
journalctl -u fan-control.service -n 50

# Current temperature
ubnt-systool cputemp

# Current PWM value
cat /sys/class/hwmon/hwmon0/pwm1

# Current configuration
cat /data/fan-control/config

# Installed release identity
cat /data/fan-control/VERSION

# Optimal PWM value
cat /data/fan-control/optimal_pwm

# Check for errors
journalctl -u fan-control.service | grep -E "ERROR|FATAL|ALERT"
```

### State Information

```bash
# View recent state transitions
journalctl -u fan-control.service | grep "STATE:"

# View recent PWM changes
journalctl -u fan-control.service | grep "SET:"

# View learning activity
journalctl -u fan-control.service | grep "LEARNING:"

# View status updates
journalctl -u fan-control.service | grep "STATUS:"
```

### Performance Analysis

```bash
# Temperature trends (last hour)
journalctl -u fan-control.service --since "1 hour ago" | grep "TEMP:"

# PWM adjustments (last hour)
journalctl -u fan-control.service --since "1 hour ago" | grep "SET:"

# State changes (last 24 hours)
journalctl -u fan-control.service --since "24 hours ago" | grep "STATE:"
```

---

## Getting Help

If you're still experiencing issues:

1. **Gather diagnostic information**:
   ```bash
   # Save complete logs
   journalctl -u fan-control.service --since "1 hour ago" > fan-control-logs.txt

   # Save configuration
   cat /data/fan-control/config > fan-control-config.txt

   # Save system info
   uname -a > system-info.txt
   ubnt-systool version >> system-info.txt
   ```

2. **Create a GitHub issue** with:
   - Device model and UniFi OS version
   - Description of the problem
   - Relevant logs
   - Configuration file
   - Steps to reproduce

3. **Check existing issues**: https://github.com/iceteaSA/unifi-fan-control/issues

---

## Hardware Compatibility Notes

### Service disappeared after a UniFi OS update

Check whether it is actually gone, or just stopped:

```bash
systemctl status fan-control.service
ls -l /data/fan-control/ /etc/systemd/system/fan-control.service
```

If both the unit and `/data/fan-control` are missing, the overlay was rebuilt — that is a
factory reset, `reset2defaults`, re-adoption, or a recovery flow, not a routine firmware
update. UniFi OS keeps the firmware as a read-only lower layer and everything you install
in an upper layer, and both halves of this install live in that upper layer. A normal
update replaces the lower layer only.

A useful tell: if other things you installed vanished at the same time, it was the
overlay, not this project. Reinstall with the one-liner in the README; your config comes
back only if `/data/fan-control/config` survived.

### Unsupported hardware: UniFi switches (USW line)

`-sh: bash: not found` on a USW means exactly what it says. Switches run BusyBox `sh`,
not bash, and nothing is installed when this happens — it fails on the first command.

Four separate things block it, not one: no bash (the daemon uses `[[ ]]`, `(( ))` and
arrays throughout), no `ubnt-systool` for CPU temperature, no systemd, and fans that are
firmware controlled rather than exposed to userspace.

The last one is the decisive one, and it is measured rather than assumed. On a USW
Enterprise 48 PoE running 7.5.9:

```
# ls /sys/class/hwmon/*/pwm* 2>/dev/null || echo "no pwm files"
no pwm files
```

No PWM files means the fans are not reachable from userspace at all, so no script can
control them — a POSIX `sh` rewrite with a different temperature source would still have
nothing to write to.

To check your own device:

```sh
ls /sys/class/hwmon/*/pwm* 2>/dev/null || echo "no pwm files"
command -v ubnt-systool || echo "no ubnt-systool"
```

If the first command ever starts printing paths after a firmware update, that changes the
answer — worth re-checking after a major version jump.

No output from the first means the fans are not software-controllable there, and no
script of any kind will help.

### Different PWM Device Paths

Some devices may use different hwmon paths:

```bash
# Find your PWM device
find /sys/class/hwmon -name "pwm*"

# Update config if different
sudo nano /data/fan-control/config
FAN_PWM_DEVICE="/sys/class/hwmon/hwmonX/pwmY"

sudo systemctl restart fan-control.service
```

### Hardware PWM Limitations

The actual PWM value may differ from requested value (e.g., setting 50 might result in ~48). This is a hardware limitation and is expected behavior.
