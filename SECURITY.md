# Security Policy

## Supported Versions

We release security updates for the following versions:

| Version | Supported          |
| ------- | ------------------ |
| main    | :white_check_mark: |
| dev     | :white_check_mark: |

## Security Considerations

### System Requirements

This software requires:
- **Root access**: Necessary for hardware control and systemd service management
- **Hardware access**: Direct access to PWM control devices
- **System integration**: Runs as a systemd service with automatic restart

### Design Philosophy

The UCG Max Fan Control system is designed with security and safety in mind:

1. **Fail-Safe Operation**:
   - Activates fans on sensor failures
   - Maintains last known safe state during errors
   - Emergency mode triggers at critical temperatures

2. **Resource Protection**:
   - Single instance enforcement via PID file
   - Atomic file operations to prevent corruption
   - Configuration validation with automatic correction

3. **Privilege Management**:
   - Runs as root only when necessary
   - Validates hardware access before operations
   - Minimal system modifications

4. **Input Validation**:
   - All configuration parameters validated against safe ranges
   - Temperature readings validated before use
   - PWM values clamped to hardware limits

## Security Best Practices

### Installation

1. **Verify source**:
   ```bash
   # Clone and inspect before running
   git clone https://github.com/iceteaSA/unifi-fan-control.git
   cd unifi-fan-control

   # Review scripts
   less fan-control.sh
   less install.sh

   # Then install
   sudo ./install.sh
   ```

2. **Use checksums** (if provided in releases)

3. **Install from trusted sources** only

### Configuration

1. **Protect configuration files**:
   ```bash
   # Verify permissions
   ls -la /data/fan-control/config

   # Should be owned by root
   sudo chown root:root /data/fan-control/config
   sudo chmod 644 /data/fan-control/config
   ```

2. **Review configuration changes**:
   - Always review changes before applying
   - Test configuration changes in safe conditions
   - Monitor logs after changes

3. **Backup configuration**:
   ```bash
   # Before making changes
   sudo cp /data/fan-control/config /data/fan-control/config.backup
   ```

### Monitoring

1. **Regular log review**:
   ```bash
   # Check for errors or anomalies
   journalctl -u fan-control.service | grep -E "ERROR|FATAL|ALERT"
   ```

2. **Monitor temperature trends**:
   ```bash
   # Ensure temperatures stay in safe ranges
   journalctl -u fan-control.service -f | grep "TEMP:"
   ```

3. **Verify state transitions**:
   ```bash
   # Check for unexpected state changes
   journalctl -u fan-control.service | grep "STATE:"
   ```

## Known Security Considerations

### Root Privileges

**Why needed**:
- Hardware PWM control requires root access
- Systemd service management requires root
- System-level temperature monitoring requires root

**Mitigation**:
- Code is open source and auditable
- Minimal system modifications
- Clear logging of all operations
- No network access required
- No external dependencies beyond system tools

### Hardware Access

**Risks**:
- Incorrect PWM values could affect hardware
- Sensor failures could lead to thermal issues

**Mitigations**:
- PWM values validated and clamped
- Emergency override at critical temperatures
- Fail-safe behavior on sensor errors
- Hardware validation on startup
- Hysteresis prevents rapid changes

### File System Access

**Access required**:
- `/data/fan-control/` - Configuration and state files
- `/sys/class/hwmon/` - Hardware control interface
- `/var/run/` - PID file
- `/etc/systemd/system/` - Service file

**Protections**:
- Atomic file operations prevent corruption
- Validation before writing
- Error handling for file operations
- Cleanup on service stop

## Reporting a Vulnerability

### Where to Report

**For security vulnerabilities**, please report via:

1. **GitHub Security Advisories** (preferred):
   - Go to: https://github.com/iceteaSA/unifi-fan-control/security/advisories
   - Click "Report a vulnerability"

2. **GitHub Issues** (for less critical issues):
   - https://github.com/iceteaSA/unifi-fan-control/issues
   - Tag with `security` label

3. **Direct contact** (for critical vulnerabilities):
   - Create a private security advisory on GitHub
   - Or create an issue with minimal details and request private disclosure

### What to Include

When reporting a security vulnerability, please include:

1. **Description**: Clear description of the vulnerability
2. **Impact**: Potential security impact and severity
3. **Reproduction**: Steps to reproduce the issue
4. **Environment**:
   - Device model (UCG-Max, UCG-Fibre, etc.)
   - UniFi OS version
   - Script version/branch
5. **Proposed fix** (if you have one)
6. **Discoverer**: Credit information if desired

### Response Timeline

- **Initial response**: Within 48 hours
- **Status update**: Within 7 days
- **Fix timeline**: Depends on severity
  - Critical: Within 7 days
  - High: Within 14 days
  - Medium: Within 30 days
  - Low: Next regular release

### Disclosure Policy

- **Coordinated disclosure**: We prefer 90 days before public disclosure
- **Credit**: Security researchers will be credited (if desired)
- **Notification**: Affected users notified via:
  - GitHub Security Advisory
  - Release notes
  - README update

## Security Updates

Security updates will be:
1. Released as soon as possible
2. Documented in CHANGELOG.md
3. Announced via GitHub releases
4. Tagged with `security` label

To apply security updates:
```bash
# Re-run installation (preserves config)
curl -fsSL https://raw.githubusercontent.com/iceteaSA/unifi-fan-control/main/install.sh | sudo bash

# Or manual update
cd unifi-fan-control
git pull
sudo ./install.sh
```

## Third-Party Dependencies

This project has minimal dependencies:

### System Dependencies
- `bash` - Shell interpreter
- `systemd` - Service management
- `ubnt-systool` - Ubiquiti system tool (temperature reading)
- Standard UNIX utilities: `awk`, `grep`, `cat`, etc.

### No external packages
- No npm packages
- No pip packages
- No compiled dependencies
- No network dependencies

This minimizes supply chain risk.

## Audit Log

Users can monitor all fan control operations via systemd journal:

```bash
# Complete audit trail
journalctl -u fan-control.service

# All configuration changes
journalctl -u fan-control.service | grep "CONFIG:"

# All state changes
journalctl -u fan-control.service | grep "STATE:"

# All PWM changes
journalctl -u fan-control.service | grep "SET:"

# All errors
journalctl -u fan-control.service | grep "ERROR:"
```

## Security Checklist for Users

- [ ] Downloaded from official GitHub repository
- [ ] Reviewed code before installation
- [ ] Installed as root with understanding of implications
- [ ] Configuration file has proper permissions (644, root-owned)
- [ ] Regularly monitoring service logs
- [ ] Temperature readings in expected ranges
- [ ] No unexpected state transitions
- [ ] Keeping software updated

## Questions?

For security-related questions that don't constitute vulnerabilities:
- Open a GitHub discussion
- Create a GitHub issue with `question` label
- Review existing documentation and issues

---

**Last updated**: 2025-11-13

Thank you for helping keep UCG Max Fan Control secure!
