# Contributing to UniFi Fan Control

Thank you for your interest in contributing to the UniFi Fan Control project! This document provides guidelines for contributing to the project.

## Code of Conduct

By participating in this project, you agree to abide by our [Code of Conduct](CODE_OF_CONDUCT.md).

## How Can I Contribute?

### Reporting Bugs

Before creating bug reports, please check existing issues to avoid duplicates. When creating a bug report, include:

- **Clear descriptive title** for the issue
- **Detailed steps to reproduce** the problem
- **Expected behavior** vs actual behavior
- **System information**:
  - Device model (UCG-Max, UCG-Fibre, UXG-Fibre, UNVR)
  - UniFi OS version
  - Current configuration (`/data/fan-control/config`)
- **Relevant logs** from `journalctl -u fan-control.service`
- **Temperature readings** and PWM values if applicable

### Suggesting Enhancements

Enhancement suggestions are tracked as GitHub issues. When creating an enhancement suggestion, include:

- **Clear descriptive title**
- **Detailed description** of the proposed functionality
- **Use cases** explaining why this enhancement would be useful
- **Possible implementation** approach if you have one in mind

### Pull Requests

1. **Fork the repository** and create your branch from `main`
2. **Make your changes**:
   - Follow the existing code style (bash best practices)
   - Add comments for complex logic
   - Update documentation if needed
3. **Test your changes**:
   - Run all four local verification gates listed below
   - Keep pull requests green across the CI Bash/mawk matrix
   - Test on actual hardware if possible
   - Verify all operational states work correctly
   - Check logs for errors or warnings
4. **Commit your changes**:
   - Use clear, descriptive commit messages
   - Reference related issues in commits
5. **Submit a pull request**:
   - Provide a clear description of changes
   - Link related issues
   - Include test results

## Development Guidelines

### Code Style

- Use clear, descriptive variable names
- Add comments for complex logic or algorithms
- Follow bash best practices:
  - Quote variables to prevent word splitting
  - Use `[[` for conditionals instead of `[`
  - Check return codes of critical operations
  - Use atomic file operations for critical files

### Configuration Management

- Never remove existing configuration parameters
- Provide default values for new parameters
- Validate user-provided values
- Log configuration changes

### Safety and Reliability

- Always validate hardware access before operations
- Implement error handling for all critical operations
- Log errors and warnings appropriately
- Ensure fan safety (never leave fans in undefined state)
- Use hysteresis to prevent rapid state oscillations

### Testing

Run the same four local gates used by CI:

```bash
bash -n fan-control.sh install.sh uninstall.sh tests/*.sh tests/lib/*.sh
bash tests/run-tests.sh
shellcheck fan-control.sh install.sh uninstall.sh tests/*.sh tests/lib/*.sh
shfmt -i 4 -ci -d fan-control.sh install.sh uninstall.sh tests/*.sh tests/lib/*.sh
```

The sandboxed suite has 9 tests after Phase 0. CI tests Bash 4.4, 5.1, 5.2, and native Ubuntu under mawk. The ShellCheck baseline in `.github/shellcheck-baseline.tsv` is temporary debt until Phase 2; it does not permit adding new warnings.

When making changes, test the following scenarios:

1. **Cold start**: Script starts with system below MIN_TEMP
2. **Hot start**: Script starts with system above MIN_TEMP
3. **Temperature transitions**: Test all state transitions
4. **Configuration changes**: Verify config reload works
5. **Error conditions**: Test sensor failures, invalid configs, etc.
6. **Long-term stability**: Run for several hours/days if possible

### Documentation

- Update README.md if adding new features
- Update TROUBLESHOOTING.md for known issues and solutions
- Document configuration parameters
- Add examples for complex features

## Project Structure

```
unifi-fan-control/
├── fan-control.sh          # Main control script
├── install.sh              # Installation script
├── uninstall.sh            # Removal script
├── fan-control.service     # Systemd service file
├── README.md               # Project documentation
├── CONTRIBUTING.md         # This file
├── CHANGELOG.md            # Version history
├── TROUBLESHOOTING.md      # Common issues and solutions
├── SECURITY.md             # Security policy
├── CODE_OF_CONDUCT.md      # Community guidelines
├── .github/workflows/ci.yml # CI matrix and lint gates
└── LICENSE                 # MIT License
```

## Commit Message Guidelines

- Use present tense ("Add feature" not "Added feature")
- Use imperative mood ("Move cursor to..." not "Moves cursor to...")
- Limit first line to 72 characters or less
- Reference issues and pull requests after the first line

Examples:
```
feat: Add support for custom PWM curves

fix: Prevent division by zero in calculate_speed()

docs: Update configuration examples in README

refactor: Improve temperature smoothing algorithm
```

## Branch Naming

- `feature/description` - New features
- `fix/description` - Bug fixes
- `docs/description` - Documentation changes
- `refactor/description` - Code refactoring

## Getting Help

- Check existing [documentation](README.md)
- Review [troubleshooting guide](TROUBLESHOOTING.md)
- Search existing [issues](https://github.com/iceteaSA/unifi-fan-control/issues)
- Create a new issue with detailed information

## Recognition

Contributors will be recognized in the project documentation. Thank you for making this project better!

## License

By contributing to this project, you agree that your contributions will be licensed under the MIT License.
