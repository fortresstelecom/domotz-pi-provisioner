# Domotz Pi Provisioner

An idempotent provisioning and maintenance script for Domotz collectors running on Raspberry Pi OS.

Designed for both **new deployments** and **existing Domotz collectors**, with automatic operating system updates, reboot management, configuration validation, and deployment health checks.

> **Vibe-coded, field-tested.** This project was developed with Microsoft Copilot and refined through hands-on testing on Raspberry Pi-based Domotz collectors.

## Features

`domotz-pi-provisioner.sh` automates and validates:

- Domotz Collector installation
- Detection and preservation of existing Domotz installations
- Snapd installation and configuration
- Required Domotz Snap interfaces
- TUN support for Domotz VPN functionality
- Raspberry Pi compatibility configuration used by Domotz
- Safe restart handling for existing collectors
- Debian package updates
- Debian security updates
- Raspberry Pi package updates
- Automatic removal of unused dependencies
- Automatic removal of unused kernel packages
- Automatic reboot when required
- Configurable reboot time
- APT/systemd automatic update timers
- Package manager health
- Unattended-upgrade dry-run validation
- Logging and final PASS/WARN/FAIL reporting

The script is **idempotent**, meaning it is designed to be safely run again on a previously configured system.

Existing Domotz installations are detected rather than intentionally replaced or reset.

## Requirements

The intended environment is:

- Raspberry Pi
- Raspberry Pi OS / compatible Debian-based Raspberry Pi installation
- Internet connectivity
- Root or `sudo` access

This project is currently focused on Raspberry Pi-based Domotz collectors. Review and test the script before using it on other Debian-based systems.

## Installation

### 1. Download the latest stable release

```bash
wget https://raw.githubusercontent.com/fortresstelecom/domotz-pi-provisioner/v1.0.1/domotz-pi-provisioner.sh
```

### 2. Make the script executable

```bash
chmod +x domotz-pi-provisioner.sh
```

### 3. Optional syntax check

```bash
bash -n domotz-pi-provisioner.sh
```

No output from `bash -n` indicates that Bash did not detect a syntax error.

### 4. Run the provisioner

```bash
sudo ./domotz-pi-provisioner.sh
```

The script performs installation/configuration and then validates the resulting system.

## Existing Domotz Installations

The provisioner can be run on Raspberry Pi systems where the Domotz Collector is already installed.

When an existing Domotz Snap installation is detected, the script preserves the existing installation while checking or applying the supporting system configuration and automatic update policy.

### Existing collectors are not restarted by default

Beginning with **v1.0.1**, an existing Domotz Collector is **not automatically restarted** during a normal provisioner run.

The default restart policy is:

```text
RESTART_DOMOTZ=auto
```

With `auto`:

- A newly installed Domotz Collector may be restarted as part of provisioning.
- An existing Domotz Collector is not restarted automatically.

This behavior helps prevent disruption when the administrator is connected to the Raspberry Pi through Domotz Remote Access.

## Domotz Restart Control

The restart policy can be explicitly controlled with the `RESTART_DOMOTZ` environment variable.

### Default behavior

```bash
sudo ./domotz-pi-provisioner.sh
```

is equivalent to:

```bash
sudo RESTART_DOMOTZ=auto ./domotz-pi-provisioner.sh
```

### Force a Domotz restart

```bash
sudo RESTART_DOMOTZ=true ./domotz-pi-provisioner.sh
```

> **Warning:** Forcing a restart of an existing Domotz Collector can interrupt a session that depends on Domotz Remote Access. Only force a restart when another management path is available or an interruption is acceptable.

### Prevent a Domotz restart

```bash
sudo RESTART_DOMOTZ=false ./domotz-pi-provisioner.sh
```

This can also be used during a new deployment when the administrator deliberately wants to defer the Collector restart.

## Domotz Compatibility Configuration

The provisioner checks and applies Raspberry Pi compatibility settings used by the official Domotz Raspberry Pi installation procedure when applicable.

These include:

- TUN module configuration
- Domotz Snap interface connections
- `/etc/ld.so.preload` compatibility handling
- `/etc/ssh/ssh_config` compatibility handling

Original copies of managed configuration files are retained under:

```text
/var/backups/domotz-pi-provisioner/
```

If compatibility configuration changes are made to an existing Collector while its restart is being skipped, the provisioner reports a warning so that a controlled restart can be performed later if required.

## Automatic Updates

The provisioner enables automatic APT package-list updates and unattended upgrades.

The unattended-upgrade policy permits eligible packages from:

- Debian base repositories
- Debian stable updates
- Debian security repositories
- Raspberry Pi Foundation repositories

The policy does **not** use a wildcard to automatically trust every third-party APT repository on the system.

The project uses a separate APT configuration fragment rather than directly modifying the distribution-supplied `50unattended-upgrades` configuration.

## Automatic Reboots

Automatic rebooting is enabled when an installed update requires a reboot.

The default reboot time is:

```text
02:00 local time
```

The provisioner configures unattended upgrades not to automatically reboot while interactive users are logged in.

### Change the reboot time

Specify a different maintenance window when running the script:

```bash
sudo REBOOT_TIME="03:00" ./domotz-pi-provisioner.sh
```

The time must use 24-hour `HH:MM` format.

Options can also be combined:

```bash
sudo REBOOT_TIME="03:00" RESTART_DOMOTZ=false ./domotz-pi-provisioner.sh
```

## Validation

The script performs a series of checks during provisioning.

Successful checks appear as:

```text
[PASS]
```

Items that may require review appear as:

```text
[WARN]
```

Configuration or operational failures appear as:

```text
[FAIL]
```

A successful run ends with:

```text
DOMOTZ PI PROVISIONER VALIDATION PASSED
```

Any `[FAIL]` condition should be investigated before considering the collector ready for deployment.

## Dry-Run Validation

By default, the provisioner runs:

```bash
unattended-upgrade --dry-run
```

near the end of the validation process.

This simulates the unattended-upgrade process without intentionally installing the pending upgrades.

The test can be skipped when necessary:

```bash
sudo RUN_DRY_RUN="false" ./domotz-pi-provisioner.sh
```

For normal deployments, leaving dry-run validation enabled is recommended.

## Logs

### Provisioner log

```text
/var/log/domotz-pi-provisioner/setup.log
```

View it with:

```bash
sudo less /var/log/domotz-pi-provisioner/setup.log
```

Or inspect the most recent output:

```bash
sudo tail -100 /var/log/domotz-pi-provisioner/setup.log
```

### Provisioner unattended-upgrade test

```text
/var/log/domotz-pi-provisioner/unattended-upgrade-dry-run.log
```

### System unattended-upgrade logs

The unattended-upgrades package also maintains its own logs under:

```text
/var/log/unattended-upgrades/
```

## Re-running the Provisioner

The script is intended to be idempotent.

Re-running:

```bash
sudo ./domotz-pi-provisioner.sh
```

will revalidate the system and apply the settings managed by the provisioner.

On an existing Domotz Collector, the default restart policy will not intentionally restart the Collector.

## Troubleshooting

Check current Domotz Snap services with:

```bash
sudo snap services domotzpro-agent-publicstore
```

Check recent Domotz Snap logs with:

```bash
sudo snap logs domotzpro-agent-publicstore -n 100
```

For unattended-upgrade diagnostics:

```bash
sudo unattended-upgrade --debug --dry-run
```

Check package dependencies with:

```bash
sudo apt-get check
```

Audit package configuration with:

```bash
sudo dpkg --audit
```

## Version History

### v1.0.1

- Prevents automatic restart of existing Domotz collectors under the default `auto` policy
- Adds `RESTART_DOMOTZ=auto|true|false`
- Separates Domotz service validation from restart behavior
- Adds Raspberry Pi compatibility configuration used by the Domotz installation procedure
- Adds backup handling for compatibility configuration files
- Adds explicit warnings when a restart could interrupt Domotz Remote Access

### v1.0.0

Initial public release.

During field testing on an existing collector, v1.0.0 unconditionally restarted the Domotz Collector during service validation. When the administrative session depended on Domotz Remote Access, this interrupted the management connection.

**v1.0.1 supersedes v1.0.0 for new deployments and existing collectors.**

## Security

This script runs with root privileges and makes system-level configuration changes.

**Always review the script before executing it on production infrastructure.**

Do not add any of the following to a public copy of this repository:

- Passwords
- API keys
- Access tokens
- Private keys
- Customer credentials
- Customer-specific network information
- Other secrets

For production use, consider downloading and reviewing the script before executing it rather than piping remote content directly into a root shell.

## Domotz Setup and Activation

For a new installation, additional Domotz Collector activation may still be required after the operating system and Collector have been provisioned.

Refer to the official Domotz Raspberry Pi installation documentation:

https://help.domotz.com/onboarding-guides/domotz-installation-raspberry-pi/

This project is an independent automation project and is **not an official Domotz distribution or installer**.

Domotz and related product names and trademarks belong to their respective owners.

## Project Scope

This project exists to make Raspberry Pi-based Domotz Collector deployments more repeatable and maintainable.

The goal is not simply to install the Domotz Snap, but to leave the host with a known update policy and a validation result that can be reviewed after deployment.

## Development Note

**Vibe-coded, field-tested.**

This project was developed with Microsoft Copilot and refined through hands-on testing on Raspberry Pi-based Domotz collectors.

## License

This project is licensed under the [MIT License](LICENSE).

## Maintainer

**Fortress Telecom, LLC**

https://github.com/fortresstelecom/domotz-pi-provisioner
