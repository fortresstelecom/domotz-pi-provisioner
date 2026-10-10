# Domotz Pi Provisioner

An idempotent provisioning, maintenance, and validation script for Domotz Collectors running on Raspberry Pi OS and compatible Debian-based Raspberry Pi systems.

The provisioner updates the operating system, validates package health, installs or preserves the Domotz Collector, configures automatic updates, manages required reboots, retains diagnostic logs across restarts, and produces a clear deployment report.

> **Vibe-coded, field-tested.** Developed with Microsoft Copilot and refined through hands-on testing on Raspberry Pi-based Domotz Collectors.

## Current Version

**v1.0.6**

## Major Changes Since v1.0.4

v1.0.6 adds:

- Interactive and YOLO provisioning modes
- A full-upgrade simulation before package changes
- Operator approval for proposed package removals in Interactive mode
- Automatic approval of proposed removals in YOLO mode
- Separation of approved actions from unresolved warnings
- Consolidated end-of-run findings and remediation guidance
- A persistent provisioner command at `/usr/local/sbin/domotz-pi-provisioner`
- Automatic post-reboot validation for YOLO deployments
- Temporary systemd oneshot service for post-reboot continuation
- Reboot-loop protection
- Persistent systemd journal storage for previous-boot diagnostics
- Process locking, trusted `PATH`, restrictive `umask`, and symbolic-link protections
- Correct script version reporting after loading `/etc/os-release`

## Features

`domotz-pi-provisioner.sh` automates and validates:

- Raspberry Pi OS and Debian-family identification
- Raspberry Pi hardware identification when available
- DNS and time-synchronization checks
- `dpkg` and APT health checks
- APT metadata refresh
- Pending-update detection
- Root-filesystem disk-space preflight
- Full-upgrade simulation
- Package-removal review and approval
- Initial full operating-system upgrade
- Post-upgrade package validation
- Snapd installation and configuration
- Domotz Collector installation
- Detection and preservation of existing Domotz installations
- Required Domotz Snap interfaces
- TUN support for Domotz VPN functionality
- Safe handling of existing Collector restarts
- Domotz service-state validation
- Unattended-upgrades policy configuration
- APT/systemd automatic-update timers
- Configurable automatic reboot time
- Persistent provisioner command installation
- Reboot-required detection
- Interactive reboot prompting
- Automatic YOLO reboot and post-reboot validation
- Reboot-loop prevention
- MOTD fallback when provisioning remains incomplete
- Persistent systemd journal storage
- Persistent setup and simulated-upgrade logs
- Consolidated PASS, WARN, FAIL, and IMPORTANT ACTION reporting

The script is designed to be rerun safely on systems it previously configured.

## Requirements

- Raspberry Pi
- Raspberry Pi OS or a compatible Debian-based Raspberry Pi installation
- Internet connectivity
- Root or `sudo` access
- At least 2 GiB of free root-filesystem space by default

The project is focused on Raspberry Pi-based Domotz Collectors. Review and test the script before using it on other Debian-based systems.

## New-System Installation

### Guided mode selection

This command downloads the current `main` version and prompts the operator to select Interactive or YOLO mode:

```bash
curl -fsSL https://raw.githubusercontent.com/fortresstelecom/domotz-pi-provisioner/main/domotz-pi-provisioner.sh -o ~/domotz-pi-provisioner.sh && chmod +x ~/domotz-pi-provisioner.sh && sudo ~/domotz-pi-provisioner.sh
```

### Fully automatic YOLO mode

```bash
curl -fsSL https://raw.githubusercontent.com/fortresstelecom/domotz-pi-provisioner/main/domotz-pi-provisioner.sh -o ~/domotz-pi-provisioner.sh && chmod +x ~/domotz-pi-provisioner.sh && sudo ~/domotz-pi-provisioner.sh --yolo
```

For a published release, replace `main` in the download URL with the desired release tag.

## Mode Selection

Running the provisioner without arguments displays:

```text
Select provisioner mode:
  1) Interactive - prompt before package removals and reboot
  2) YOLO        - approve package removals and reboot automatically

Mode [1/2]:
```

### Interactive mode

Interactive mode:

- Displays package removals proposed by the upgrade simulation
- Requires explicit approval before package removals
- Prompts before rebooting
- Defaults to No at approval prompts
- Requires an interactive terminal

### YOLO mode

Run YOLO mode directly with:

```bash
sudo domotz-pi-provisioner --yolo
```

YOLO mode:

- Automatically approves package removals identified by the simulation
- Runs unattended after startup
- Automatically reboots when required
- Automatically performs post-reboot validation
- Retains fatal safety checks
- Prevents repeated automatic reboot cycles

YOLO does not bypass package-health checks, disk-space validation, DNS checks, symbolic-link protections, process locking, or fatal installation errors.

## Initial System Update

Before Domotz configuration, the provisioner:

1. Checks `dpkg` and APT health.
2. Refreshes package metadata.
3. Counts pending updates.
4. Verifies available disk space.
5. Simulates a full upgrade.
6. Reviews proposed package removals.
7. Performs the full system update.
8. Checks package health and pending updates again.

The simulated upgrade plan is saved at:

```text
/var/log/domotz-pi-provisioner/full-upgrade-plan.log
```

## Package-Removal Handling

A full upgrade may propose removing installed packages.

### Interactive mode

The proposed removals are displayed and the operator is asked:

```text
Allow these package removals and continue? [y/N]:
```

Approved removals are recorded under `IMPORTANT ACTIONS` rather than counted as warnings.

### YOLO mode

YOLO automatically approves the simulated removals and records that decision under `IMPORTANT ACTIONS`.

## Disk-Space Preflight

The default minimum available root-filesystem space is:

```text
2048 MiB
```

Override it when necessary:

```bash
sudo MIN_FREE_ROOT_MB="4096" ./domotz-pi-provisioner.sh
```

The provisioner stops before package installation if the minimum is not met.

## Existing Domotz Installations

Existing Domotz Snap installations are detected and preserved.

The default restart policy is:

```text
RESTART_DOMOTZ=auto
```

With `auto`:

- A newly installed Collector may be restarted during provisioning.
- An existing Collector is not restarted automatically.

This protects sessions that depend on Domotz Remote Access.

### Force a Domotz restart

```bash
sudo RESTART_DOMOTZ=true ./domotz-pi-provisioner.sh
```

> **Warning:** Forcing a restart may interrupt a session that depends on Domotz Remote Access.

### Prevent a Domotz restart

```bash
sudo RESTART_DOMOTZ=false ./domotz-pi-provisioner.sh
```

## Persistent Provisioner Command

Each successful startup installs the current script at:

```text
/usr/local/sbin/domotz-pi-provisioner
```

Future runs can use:

```bash
sudo domotz-pi-provisioner
```

or:

```bash
sudo domotz-pi-provisioner --yolo
```

The provisioner detects when it is already running from the persistent destination and does not attempt to overwrite itself.

## Reboot Workflow

### Interactive mode

When a reboot is required, the operator is prompted:

```text
Reboot required. Reboot now? [y/N]:
```

If provisioning still requires completion after reboot, the login MOTD directs the operator to rerun:

```bash
sudo domotz-pi-provisioner
```

### YOLO mode

When YOLO detects a required reboot, it:

1. Creates a completion marker.
2. Installs a temporary systemd oneshot service.
3. Keeps an MOTD fallback reminder.
4. Reboots automatically.
5. Waits for `network-online.target` after startup.
6. Runs the persistent provisioner with `--yolo --post-reboot`.
7. Performs final validation.
8. Removes the marker, MOTD, and temporary service after successful completion.

The temporary service is:

```text
/etc/systemd/system/domotz-pi-provisioner-post-reboot.service
```

Check it with:

```bash
sudo systemctl status domotz-pi-provisioner-post-reboot.service
```

View its log with:

```bash
sudo journalctl -u domotz-pi-provisioner-post-reboot.service --no-pager
```

### Reboot-loop protection

If the automatic post-reboot run still detects another reboot requirement, the provisioner does not initiate another automatic reboot. It leaves the fallback MOTD in place and directs the operator to review the system and service journal.

## Persistent System Journal

v1.0.6 enables persistent systemd journal storage by:

- Creating `/var/log/journal` when needed
- Applying system journal permissions with `systemd-tmpfiles`
- Flushing the current runtime journal to disk

This preserves system, kernel, networking, SSH, package, and service logs across reboot or power interruption.

List recorded boots:

```bash
sudo journalctl --list-boots
```

Review the previous boot:

```bash
sudo journalctl -b -1
```

Check persistent journal usage:

```bash
sudo journalctl --directory=/var/log/journal --disk-usage
```

## Automatic Updates

The provisioner configures:

- Daily package-list updates
- Daily unattended upgrades
- Automatic cleanup of unused dependencies
- Automatic cleanup of unused kernel packages
- Automatic reboot when required
- Prevention of automatic reboot while interactive users are logged in
- Configurable reboot time

The policy permits eligible packages from:

- Debian base repositories
- Debian updates
- Debian security repositories
- Raspberry Pi Foundation repositories

The script uses a separate local policy file rather than directly changing the distribution-supplied unattended-upgrades configuration.

## Automatic Reboot Time

The default automatic reboot time is:

```text
02:00 local time
```

Set another maintenance time with:

```bash
sudo REBOOT_TIME="03:00" ./domotz-pi-provisioner.sh
```

The value must use 24-hour `HH:MM` format.

## Reporting

The provisioner reports:

- `[PASS]` for successful validation
- `[INFO]` for normal actions and operator-approved changes
- `[WARN]` for unresolved or unexpected conditions
- `[FAIL]` for provisioning or validation failures

### Important Actions

Approved package removals appear under:

```text
IMPORTANT ACTIONS
```

These actions remain visible for audit purposes but do not increase the warning count.

### Findings Requiring Review

Warnings and failures are repeated near the end under:

```text
FINDINGS REQUIRING REVIEW
```

The summary includes context, diagnostic commands, remediation guidance, and relevant log paths so operators do not need terminal scrollback.

## Logs

Provisioner output:

```text
/var/log/domotz-pi-provisioner/setup.log
```

Upgrade simulation:

```text
/var/log/domotz-pi-provisioner/full-upgrade-plan.log
```

View recent provisioner output:

```bash
sudo tail -200 /var/log/domotz-pi-provisioner/setup.log
```

View APT transaction output:

```bash
sudo less -r /var/log/apt/term.log
```

Review previous system boot:

```bash
sudo journalctl -b -1
```

## Troubleshooting

### Check package state

```bash
sudo dpkg --audit
sudo apt-get check
```

### Recover an interrupted package configuration

```bash
sudo dpkg --configure -a
```

If dependency repair is required:

```bash
sudo apt-get -f install
```

Do not delete APT/dpkg lock files while package processes are active.

### Check Domotz service state

```bash
sudo snap services domotzpro-agent-publicstore
```

### Check recent Domotz logs

```bash
sudo snap logs domotzpro-agent-publicstore -n 100
```

### Check required Snap interfaces

```bash
sudo snap connections domotzpro-agent-publicstore
```

### Check TUN support

```bash
ls -l /dev/net/tun
lsmod | grep '^tun'
```

### Check automatic-update timers

```bash
systemctl status apt-daily.timer apt-daily-upgrade.timer
```

### Check whether a reboot is required

```bash
if [ -f /var/run/reboot-required ]; then cat /var/run/reboot-required; else echo "No reboot required"; fi
```

## Security Design

v1.0.6 includes:

- Trusted root `PATH`
- Restrictive `umask`
- Explicit root ownership and permissions
- Symbolic-link destination checks
- Nonblocking process lock
- Full-upgrade simulation
- Interactive approval or recorded YOLO approval for package removals
- Disk-space validation
- Immediate stop on fatal package or Domotz installation failures
- One-cycle automatic reboot protection
- Persistent logs for post-incident review

This script runs with root privileges and makes system-level changes. Review it before production deployment.

Do not store credentials, API keys, access tokens, private keys, customer secrets, or customer-specific network information in the public repository.

## Version History

### v1.0.6

- Added Interactive and YOLO run modes
- Added mode-selection prompt when no argument is supplied
- Added `--yolo` for unattended provisioning
- Added automatic package-removal approval in YOLO mode
- Added operator package-removal approval in Interactive mode
- Added consolidated findings and remediation guidance
- Added `IMPORTANT ACTIONS` reporting
- Added automatic post-reboot YOLO validation using systemd
- Added reboot-loop protection
- Added persistent system journal storage
- Added trusted root path, restrictive permissions, symbolic-link protections, and process locking
- Added upgrade simulation and package-removal review
- Corrected script-version reporting
- Corrected persistent-launcher self-copy behavior

### v1.0.5

- Added security hardening and upgrade safeguards
- Added process locking and privileged-path protections
- Added full-upgrade simulation
- Blocked unreviewed package removals
- Corrected version reporting and persistent-launcher behavior

### v1.0.4

- Added initial full system update workflow
- Added package-health checks and disk-space preflight
- Added reboot-required detection and operator prompt
- Added persistent provisioner command
- Added post-reboot MOTD completion reminder

### v1.0.3

- Introduced mandatory initial system updating
- Removed the unattended-upgrade dry-run requirement
- Added reboot-requirement reporting

### v1.0.2

- Corrected Domotz Snap service-state validation
- Made existing-Collector validation read-only

### v1.0.1

- Prevented automatic restart of existing Domotz Collectors under the default policy
- Added configurable restart behavior
- Added Raspberry Pi compatibility configuration

### v1.0.0

Initial public release.

## Domotz Activation

New installations may still require Collector activation after provisioning.

Refer to the official Domotz Raspberry Pi installation documentation for activation requirements.

This is an independent automation project and is not an official Domotz distribution or installer. Domotz and related product names and trademarks belong to their respective owners.

## Project Scope

The goal is to leave the Collector host with:

- A fully updated operating-system baseline
- A validated Domotz Collector
- A known automatic-update policy
- A controlled reboot workflow
- A clear post-reboot completion state
- Persistent service and system diagnostics
- A persistent maintenance command
- A final result suitable for technical review

## License

This project is licensed under the [MIT License](LICENSE).

## Maintainer

**Fortress Telecom, LLC**
