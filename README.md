# Domotz Pi Provisioner

An idempotent provisioning, maintenance, and validation script for Domotz Collectors running on Raspberry Pi OS and compatible Debian-based Raspberry Pi systems.

> **Vibe-coded, field-tested.** Developed with Microsoft Copilot and refined through hands-on testing on Raspberry Pi-based Domotz Collectors.

## Current Version

**v1.0.7**

## What Is New in v1.0.7

v1.0.7 improves the handoff after a new Domotz Collector installation.

When Domotz is installed during the current run, the provisioner now:

- Determines the Pi's preferred LAN IPv4 address
- Inspects active TCP listeners associated with Domotz Snap processes
- Prefers port `3000` if that listener is present
- Uses a different detected Domotz listener when the WebUI is not on port `3000`
- Adds WebUI detection status and address to the final deployment report
- Prints a large `DOMOTZ CONFIGURATION REQUIRED` block at the end
- Provides a copy-ready browser URL when the WebUI is detected
- Falls back to Domotz app onboarding guidance when no WebUI listener can be identified

The onboarding notice is shown only when Domotz was newly installed during the current run. Existing Collectors do not receive a first-time setup notice on every maintenance run.

## New-System Installation

### Guided mode

```bash
curl -fsSL https://raw.githubusercontent.com/fortresstelecom/domotz-pi-provisioner/main/domotz-pi-provisioner.sh -o ~/domotz-pi-provisioner.sh && chmod +x ~/domotz-pi-provisioner.sh && sudo ~/domotz-pi-provisioner.sh
```

### YOLO mode

```bash
curl -fsSL https://raw.githubusercontent.com/fortresstelecom/domotz-pi-provisioner/main/domotz-pi-provisioner.sh -o ~/domotz-pi-provisioner.sh && chmod +x ~/domotz-pi-provisioner.sh && sudo ~/domotz-pi-provisioner.sh --yolo
```

## Run Modes

Running without arguments prompts for:

```text
1) Interactive - prompt before package removals and reboot
2) YOLO        - approve package removals and reboot automatically
```

YOLO automatically approves simulated package removals and one reboot cycle. It does not bypass fatal package-health, disk-space, DNS, file-safety, or installation checks.

## Domotz First-Time Setup

After a new installation, the final output may contain:

```text
==============================================================================
                     DOMOTZ CONFIGURATION REQUIRED
==============================================================================

The Domotz Collector was installed during this run and may still require
first-time configuration.

Open this URL from a browser on the same network:

    http://192.168.1.42:3000

Complete the Domotz onboarding before considering this deployment finished.
==============================================================================
```

The address and port are discovered from the running system. The script does not assume port `3000` when a different Domotz listener is detected.

If the WebUI cannot be identified, the script directs the operator to use the Domotz app to add or activate the site.

## Core Features

- Package-manager health validation
- APT metadata refresh and pending-update count
- Root-filesystem disk-space preflight
- Full-upgrade simulation
- Interactive or recorded YOLO approval for package removals
- Full operating-system update
- Domotz installation or existing-Collector preservation
- Required Domotz Snap interface validation
- TUN support
- Existing Collector restart protection
- Automatic-update policy and timer validation
- Persistent command at `/usr/local/sbin/domotz-pi-provisioner`
- Interactive reboot workflow
- YOLO automatic reboot and post-reboot validation
- Reboot-loop protection
- Persistent journald storage
- Consolidated important actions, warnings, failures, and remediation guidance
- First-time Domotz WebUI discovery and onboarding notice

## Persistent Diagnostics

Provisioner output:

```text
/var/log/domotz-pi-provisioner/setup.log
```

Upgrade simulation:

```text
/var/log/domotz-pi-provisioner/full-upgrade-plan.log
```

Previous boot:

```bash
sudo journalctl -b -1
```

Recorded boots:

```bash
sudo journalctl --list-boots
```

## Interrupted Upgrade Recovery

Check package state:

```bash
sudo dpkg --audit
sudo apt-get check
```

Resume interrupted configuration:

```bash
sudo dpkg --configure -a
```

Repair dependencies only when required:

```bash
sudo apt-get -f install
```

## Existing Collector Restart Policy

The default is:

```text
RESTART_DOMOTZ=auto
```

With `auto`, newly installed Collectors may be restarted, while existing Collectors are preserved without an intentional restart.

Force a controlled restart:

```bash
sudo RESTART_DOMOTZ=true domotz-pi-provisioner
```

Never force a Collector restart when the current management session depends on Domotz Remote Access unless another management path is available.

## Security Design

- Trusted root `PATH`
- Restrictive `umask`
- Explicit file ownership and permissions
- Symbolic-link destination checks
- Nonblocking process lock
- Upgrade simulation
- Disk-space validation
- Immediate stop on fatal installation errors
- One-cycle automatic reboot protection
- Persistent logs for incident review

This script runs with root privileges and makes system-level changes. Review the source before production deployment.

## Version History

### v1.0.7

- Added preferred LAN IPv4 discovery
- Added dynamic Domotz WebUI listener detection
- Added first-time setup URL to the final report
- Added large end-of-run onboarding notice for newly installed Collectors
- Added fallback Domotz app guidance when no WebUI is detected

### v1.0.6

- Added Interactive and YOLO modes
- Added full-upgrade simulation and package-removal approval
- Added automatic YOLO post-reboot validation
- Added reboot-loop protection
- Added persistent journald storage
- Added consolidated findings and important-actions reporting
- Added security hardening and persistent command installation

### v1.0.5

- Added security hardening and upgrade safeguards
- Corrected version and persistent-launcher behavior

### v1.0.4

- Added package-health checks, disk-space preflight, persistent command, and reboot workflow

## License

Licensed under the [MIT License](LICENSE).

## Maintainer

**Fortress Telecom, LLC**
