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

The script is **idempotent**, meaning it is designed to be safely run again on a previously configured system. Existing Domotz installations are detected rather than intentionally replaced or reset.

## Requirements

The intended environment is:

- Raspberry Pi
- Raspberry Pi OS / compatible Debian-based Raspberry Pi installation
- Internet connectivity
- Root or `sudo` access

This project is currently focused on Raspberry Pi-based Domotz collectors. Review and test the script before using it on other Debian-based systems.

## Installation

### 1. Download the script

```bash
wget https://raw.githubusercontent.com/fortresstelecom/domotz-pi-provisioner/main/domotz-pi-provisioner.sh
```

### 2. Make the script executable

```bash
chmod +x domotz-pi-provisioner.sh
```

### 3. Run it

```bash
sudo ./domotz-pi-provisioner.sh
```

The script performs installation/configuration and then validates the resulting system.

## Existing Domotz Installations

The script can also be run on Raspberry Pi systems where the Domotz Collector is already installed.

When an existing Domotz Snap installation is detected, the script is designed to preserve the existing installation while checking or applying the supporting system configuration and automatic update policy.

This makes the script useful for bringing previously deployed 
