#!/bin/bash
set -e

# Check for root privileges
if [ "$(id -u)" -ne 0 ]; then
    echo "Error: This script must be run as root (sudo)"
    exit 1
fi

# Installer-only path and command seams support sandboxed tests.
INSTALL_DIR="${FAN_CONTROL_INSTALL_DIR:-/data/fan-control}"
SERVICE_FILE="${FAN_CONTROL_SERVICE_FILE:-/etc/systemd/system/fan-control.service}"
SYSTEMCTL="${FAN_CONTROL_SYSTEMCTL:-systemctl}"

# Check for systemd availability
if ! command -v "$SYSTEMCTL" >/dev/null 2>&1; then
    echo "Error: systemd is required but not found"
    exit 1
fi

# Check for curl availability
if ! command -v curl >/dev/null 2>&1; then
    echo "Error: curl is required but not found"
    exit 1
fi

# Repository information
REPO_OWNER="iceteaSA"
REPO_NAME="unifi-fan-control"
BRANCH="${FAN_CONTROL_BRANCH:-main}" # Use environment variable if set, otherwise default to main
BASE_URL="https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$BRANCH"

echo "Installing from branch: $BRANCH"

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create directory for fan control
mkdir -p "$INSTALL_DIR" || {
    echo "Error: Failed to create directory $INSTALL_DIR"
    exit 1
}

# Check if directory is writable
if [ ! -w "$INSTALL_DIR" ]; then
    echo "Error: Directory $INSTALL_DIR is not writable"
    exit 1
fi

# Function to get a file from local directory or download from GitHub
get_file() {
    local filename="$1"
    local destination="$2"

    # Try to use local file first
    if [ -f "$SCRIPT_DIR/$filename" ]; then
        echo "Using local file: $filename"
        cp "$SCRIPT_DIR/$filename" "$destination"
    else
        echo "Downloading $filename from repository..."
        if ! curl -fsSL "$BASE_URL/$filename" -o "$destination"; then
            echo "Error: Failed to download $filename"
            exit 1
        fi
    fi
}

# Get fan control script
get_file "fan-control.sh" "$INSTALL_DIR/fan-control.sh"
chmod +x "$INSTALL_DIR/fan-control.sh"

# Get uninstall script
get_file "uninstall.sh" "$INSTALL_DIR/uninstall.sh"
chmod +x "$INSTALL_DIR/uninstall.sh"

# Install systemd service
get_file "fan-control.service" "$SERVICE_FILE"

# Verify service file was created
if [ ! -f "$SERVICE_FILE" ]; then
    echo "Error: Failed to create service file"
    exit 1
fi

# Configure systemd service
echo "Reloading systemd configuration..."
"$SYSTEMCTL" daemon-reload || {
    echo "Error: Failed to reload systemd configuration"
    exit 1
}

# Smart service management
if "$SYSTEMCTL" is-active --quiet fan-control.service; then
    echo "Service already running - performing hot update"
    if ! "$SYSTEMCTL" restart fan-control.service; then
        echo "Error: Failed to restart service"
        echo "Check service status with: systemctl status fan-control.service"
        exit 1
    fi
    echo "Service successfully updated and restarted"
else
    echo "Performing fresh installation"
    if ! "$SYSTEMCTL" enable --now fan-control.service; then
        echo "Error: Failed to enable and start service"
        echo "Check service status with: systemctl status fan-control.service"
        exit 1
    fi
    echo "Service successfully enabled and started"
fi

echo "Installation successful!"
echo "Configuration: nano $INSTALL_DIR/config"
echo "Status check: journalctl -u fan-control.service -f"
