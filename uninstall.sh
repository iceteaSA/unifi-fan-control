#!/bin/bash
set -e

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo)"
    exit 1
fi

# Check for systemd availability
if ! command -v systemctl >/dev/null 2>&1; then
    echo "Error: systemd is required but not found"
    exit 1
fi

# Stop and disable service
systemctl stop fan-control.service 2>/dev/null || true
systemctl disable fan-control.service 2>/dev/null || true

# Reset all fan PWM channels to 0
# Mirrors the detection logic in fan-control.sh to find all active channels
reset_ok=false

# Strategy 1: pwm files directly in hwmon class directories
for pwm_file in /sys/class/hwmon/hwmon*/pwm[1-9]; do
    if [ -e "$pwm_file" ]; then
        echo "Resetting $pwm_file to 0..."
        echo 0 >"$pwm_file" 2>/dev/null && reset_ok=true
    fi
done

# Strategy 2: raw device paths (for UDM-SE where class dir has no pwm files)
if [ "$reset_ok" = false ]; then
    for hwmon_dir in /sys/class/hwmon/hwmon*; do
        dev_path=$(readlink -f "$hwmon_dir/device" 2>/dev/null) || continue
        for pwm_file in "$dev_path"/pwm[1-9]; do
            if [ -e "$pwm_file" ]; then
                echo "Resetting $pwm_file to 0..."
                echo 0 >"$pwm_file" 2>/dev/null && reset_ok=true
            fi
        done
    done
fi

[ "$reset_ok" = false ] && echo "Warning: No PWM devices found to reset"

# Remove system files
echo "Removing system files..."
rm -f /etc/systemd/system/fan-control.service || echo "Warning: Could not remove service file"
rm -f /var/run/fan-control.pid || echo "Warning: Could not remove PID file"

# Remove data files
echo "Removing data files..."
if [ -d "/data/fan-control" ]; then
    rm -rf /data/fan-control || {
        echo "Warning: Could not remove data directory"
        echo "You may need to manually remove /data/fan-control"
    }
else
    echo "Data directory not found, skipping"
fi

# Reload systemd
systemctl daemon-reload

echo "Uninstallation complete. All components removed."
