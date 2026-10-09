# Domotz Pi Provisioner

An idempotent provisioning and maintenance script for Domotz Collectors running on Raspberry Pi OS and compatible Debian-based Raspberry Pi systems.

Domotz Pi Provisioner brings the operating system fully up to date before configuring the Collector and its ongoing automatic-update policy. It supports both new deployments and existing Domotz installations while avoiding unnecessary Collector restarts during remote maintenance.

> **Vibe-coded, field-tested.** Developed with Microsoft Copilot and refined through hands-on testing on Raspberry Pi-based Domotz Collectors.

## Current Release

**v1.0.4**

Key v1.0.4 improvements include:

- Mandatory initial full system update before provisioning
- Package-manager health checks before and after the update
- Disk-space preflight before starting the full upgrade
- Safe handling of existing Domotz Collectors
- Automatic-update configuration after the initial update
- Controlled reboot prompt when required
- Persistent post-reboot validation command
- MOTD reminder until final post-reboot validation succeeds

## Features

`domotz-pi-provisioner.sh` automates and validates:

- Debian and Raspberry Pi OS identification
- Raspberry Pi hardware detection
- DNS and time-synchronization checks
- `dpkg` and APT health validation
- APT metadata refresh
- Pending-update detection
- Root-filesystem disk-space preflight
- Mandatory initial full system update
- Post-upgrade package-manager validation
- Remaining-update detection
- Snapd installation and configuration
- Domotz Collector installation
- Detection and preservation of existing Domotz installations
- Required Domotz Snap interfaces
- TUN support for Domotz VPN functionality
- Raspberry Pi compatibility configuration used by Domotz
- Safe restart handling for existing Collectors
- Domotz service-status validation
- Automatic Debian and Raspberry Pi package updates
- Automatic removal of unused dependencies
- Automatic removal of unused kernel packages
- Automatic reboot when required
- Configurable automatic reboot time
- APT/systemd automatic-update timers
- Persistent setup logging
- Post-reboot completion tracking
- MOTD reminder until provisioning is fully validated
- Final PASS, WARN, and FAIL reporting

The script is designed to be idempotent. It can be rerun to validate the system and reapply the settings managed by the provisioner.

## Provisioning Workflow

```text
Preflight validation
        ↓
APT metadata refresh
        ↓
Disk-space validation
        ↓
Full system update
        ↓
Post-update package validation
        ↓
Required package installation
        ↓
Domotz provisioning and validation
        ↓
Automatic-update configuration
        ↓
Final validation
        ↓
Reboot prompt, when required
        ↓
Post-reboot provisioner rerun
        ↓
Provisioning complete
```

## Requirements

The intended environment is:

- Raspberry Pi
- Raspberry Pi OS or a compatible Debian-based Raspberry Pi installation
- Internet connectivity
- Root or `sudo` access
- Sufficient free disk space for the initial system upgrade

The default minimum free-space requirement is **2 GiB** on the root filesystem.

This project is focused on Raspberry Pi-based Domotz Collectors. Review and test the script before using it on other Debian-based systems.

## Installation

### 1. Download v1.0.4

```bash
wget https://raw.githubusercontent.com/fortresstelecom/domotz-pi-provisioner/v1.0.4/domotz-pi-provisioner.sh
```

### 2. Make the script executable

```bash
chmod +x domotz-pi-provisioner.sh
```

### 3. Validate Bash syntax

```bash
bash -n domotz-pi-provisioner.sh
```

No output indicates that Bash did not detect a syntax error.

### 4. Run the provisioner

```bash
sudo ./domotz-pi-provisioner.sh
```

For a large initial update, consider running the provisioner inside a persistent terminal session such as `tmux`.

## Initial System Update

The provisioner refreshes APT metadata and installs all currently available updates before configuring Domotz or enabling ongoing automatic updates.

This establishes a fully updated operating-system baseline before provisioning continues.

The initial update uses a noninteractive full upgrade and preserves existing package configuration files when package prompts occur.

The provisioner records:

- Number of pending updates before the upgrade
- Number of remaining updates after the upgrade
- Package-manager health before and after the upgrade
- Whether the update requires a reboot

## Disk-Space Preflight

Before starting the full system update, the provisioner checks available space on the root filesystem.

The default requirement is:

```text
2048 MiB
```

If insufficient space is available, the provisioner stops before package installation begins.

### Change the minimum free-space requirement

```bash
sudo MIN_FREE_ROOT_MB="4096" ./domotz-pi-provisioner.sh
```

The final deployment report records the free-space value measured during the preflight.

## Existing Domotz Installations

The provisioner can be run on Raspberry Pi systems where the Domotz Collector is already installed.

When an existing Domotz Snap installation is detected, the script preserves it while validating or applying the supporting system configuration and automatic-update policy.

### Existing Collectors are not restarted by default

The default restart policy is:

```text
RESTART_DOMOTZ=auto
```

With `auto`:

- A newly installed Domotz Collector may be restarted during initial provisioning.
- An existing Domotz Collector is not automatically restarted.

This helps prevent disruption when the administrator is connected through Domotz Remote Access.

## Domotz Restart Control

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

> **Warning:** Forcing a restart of an existing Collector may interrupt a session that depends on Domotz Remote Access. Only force a restart when another management path is available or the interruption is acceptable.

### Prevent all Domotz restarts

```bash
sudo RESTART_DOMOTZ=false ./domotz-pi-provisioner.sh
```

## Domotz Compatibility Configuration

The provisioner checks and applies Raspberry Pi compatibility settings used by the Domotz installation procedure when applicable.

These include:

- Required Domotz Snap interface connections
- TUN module configuration
- `/etc/ld.so.preload` compatibility handling
- `/etc/ssh/ssh_config` compatibility handling

Original copies of managed configuration files are retained under:

```text
/var/backups/domotz-pi-provisioner/
```

## Domotz Service Validation

The provisioner validates the Collector with:

```bash
sudo snap services domotzpro-agent-publicstore
```

A healthy existing Collector should report a service state similar to:

```text
Startup  Current
 enabled  active
```

The provisioner reads the `Current` column when validating active service status.

## Automatic Updates

After the initial full system update completes, the provisioner configures unattended updates.

The policy permits eligible packages from:

- Debian base repositories
- Debian stable updates
- Debian security repositories
- Raspberry Pi Foundation repositories

The policy does not use a wildcard to trust every third-party APT repository automatically.

The provisioner configures:

- Daily package-list updates
- Daily unattended upgrades
- Removal of unused dependencies
- Removal of unused kernel packages
- Automatic reboot when required
- Prevention of automatic reboot while interactive users are logged in
- A configurable reboot time

The provisioner uses a separate local APT policy file rather than directly editing the distribution-supplied unattended-upgrades policy.

## Automatic Reboot Time

The default automatic reboot time is:

```text
02:00 local time
```

To use another maintenance window:

```bash
sudo REBOOT_TIME="03:00" ./domotz-pi-provisioner.sh
```

The time must use 24-hour `HH:MM` format.

Options can be combined:

```bash
sudo REBOOT_TIME="03:00" MIN_FREE_ROOT_MB="4096" ./domotz-pi-provisioner.sh
```

## Interactive Reboot Prompt

When the initial update requires a reboot, the provisioner completes its remaining configuration and then prompts:

```text
Reboot required. Reboot now? [y/N]:
```

Responses:

- `Y` or `Yes` performs a graceful reboot.
- `N`, `No`, or Enter defers the reboot.
- Noninteractive runs never initiate the reboot automatically.

## Persistent Provisioner Command

Each run installs a persistent copy of the provisioner at:

```text
/usr/local/sbin/domotz-pi-provisioner
```

This provides a short maintenance command that survives reboot:

```bash
sudo domotz-pi-provisioner
```

## Post-Reboot Completion Workflow

When a reboot is required, the provisioner creates:

```text
/var/lib/domotz-pi-provisioner/rerun-required
/etc/motd.d/99-domotz-pi-provisioner
```

At the next login, the MOTD displays:

```text
*** DOMOTZ PI PROVISIONING INCOMPLETE ***
A reboot was required during provisioning.
Rerun the provisioner to complete final validation.

Copy/paste:
sudo domotz-pi-provisioner
```

After reboot, run:

```bash
sudo domotz-pi-provisioner
```

When post-reboot validation succeeds and no further reboot is required, the provisioner removes the completion marker and MOTD reminder.

The persistent command remains installed for future maintenance runs.

## Validation Results

Checks are reported as:

```text
[PASS]
```

for successful validation,

```text
[WARN]
```

for conditions requiring review, and

```text
[FAIL]
```

for failed configuration or operational checks.

A successful run ends with:

```text
DOMOTZ PI PROVISIONER VALIDATION PASSED
```

A reboot-required warning is expected when the initial update installs a new kernel, firmware, or another package that requires a restart.

## Logs

The provisioner log is stored at:

```text
/var/log/domotz-pi-provisioner/setup.log
```

View it with:

```bash
sudo less /var/log/domotz-pi-provisioner/setup.log
```

View recent entries with:

```bash
sudo tail -100 /var/log/domotz-pi-provisioner/setup.log
```

System unattended-upgrade logs are stored under:

```text
/var/log/unattended-upgrades/
```

## Troubleshooting

### Check Domotz service state

```bash
sudo snap services domotzpro-agent-publicstore
```

### Check recent Domotz logs

```bash
sudo snap logs domotzpro-agent-publicstore -n 100
```

### Check package dependencies

```bash
sudo apt-get check
```

### Audit incomplete package operations

```bash
sudo dpkg --audit
```

### Check for a required reboot

```bash
if [ -f /var/run/reboot-required ]; then cat /var/run/reboot-required; else echo "No reboot required"; fi
```

### Check pending updates

```bash
apt list --upgradable 2>/dev/null
```

## Version History

### v1.0.4

- Adds mandatory initial full system updating before Domotz provisioning
- Adds pre- and post-upgrade package-manager health validation
- Adds pending-update counts before and after the upgrade
- Adds a configurable disk-space preflight
- Adds an interactive reboot prompt
- Adds persistent post-reboot completion tracking
- Adds an MOTD reminder when post-reboot validation remains incomplete
- Installs a persistent `sudo domotz-pi-provisioner` maintenance command
- Removes the MOTD reminder after successful post-reboot validation

### v1.0.3

- Introduced mandatory initial full system updating
- Removed the unattended-upgrade dry-run requirement
- Added reboot-requirement reporting

### v1.0.2

- Corrected Domotz Snap service-status validation
- Made existing-Collector service validation read-only

### v1.0.1

- Prevented automatic restart of existing Domotz Collectors under the default policy
- Added configurable restart behavior
- Added Raspberry Pi compatibility configuration

### v1.0.0

Initial public release.

v1.0.0 unconditionally restarted the Collector during service validation. A session depending on Domotz Remote Access could therefore be interrupted. Later releases supersede v1.0.0 for new and existing deployments.

## Security

This script runs with root privileges and makes system-level configuration changes.

**Always review the script before executing it on production infrastructure.**

Do not add any of the following to a public repository or fork:

- Passwords
- API keys
- Access tokens
- Private keys
- Customer credentials
- Customer-specific network information
- Other secrets

For production use, download and review the script before executing it rather than piping remote content directly into a root shell.

## Domotz Setup and Activation

New installations may still require Collector activation after the operating system and Collector have been provisioned.

Refer to the [official Domotz Raspberry Pi installation documentation](https://help.domotz.com/onboarding-guides/domotz-installation-raspberry-pi/).

This project is an independent automation project and is not an official Domotz distribution or installer.

Domotz and related product names and trademarks belong to their respective owners.

## Project Scope

This project exists to make Raspberry Pi-based Domotz Collector deployments repeatable, maintainable, and verifiable.

The goal is to leave the host with:

- A fully updated operating-system baseline
- A validated Domotz Collector
- A known automatic-update policy
- A controlled reboot workflow
- A clear post-reboot validation state
- A persistent maintenance command
- A final deployment result that can be reviewed and logged

## Development Note

**Vibe-coded, field-tested.**

Developed with Microsoft Copilot and refined through hands-on testing on Raspberry Pi-based Domotz Collectors.

## License

This project is licensed under the [MIT License](LICENSE).

## Maintainer

**Fortress Telecom, LLC**

[View the Domotz Pi Provisioner repository](https://github.com/fortresstelecom/domotz-pi-provisioner)
