# Domotz Pi Provisioner v1.1.0-beta.3

This pre-release beta adds transactional NetworkManager-to-systemd-networkd migration, dynavlan integration, configurable rollback protection, and a reconnect workflow designed for remote technicians.

> Use only on non-critical Collectors with console, on-site, or other out-of-band recovery access.

## UX updates

### Direct rollback-minute entry

Interactive mode now asks:

```text
Rollback window in minutes [3-30, default 5]:
```

- Enter a whole number from `3` through `30`.
- Press Enter to use 5 minutes.
- Invalid input displays the valid range and prompts again.

### Reconnect workflow

Before migration, the provisioner now explains:

```text
If SSH disconnects, locate the device using the MAC address above and reconnect
to its current IP address.

After reconnecting, run:

  sudo domotz-pi-provisioner

to confirm the networking update.

Your next login will display the migration status and the next steps.
If the migration is not confirmed before the rollback timer expires,
the previous network configuration will be restored automatically.
```

The technician only needs the normal persistent command:

```bash
sudo domotz-pi-provisioner
```

When a migration is pending, the command automatically opens a migration menu instead of starting another provisioning run:

```text
PENDING NETWORK MIGRATION

K) Keep the new network configuration
R) Restore the previous network configuration now
```

### Login notice

While a migration is pending, each shell login displays:

- Management interface
- MAC address
- Original IP
- Current IP
- Exact rollback date/time and timezone
- Remaining rollback time
- The command to review and confirm the update

The notice is removed when the migration is committed or rollback completes successfully.

## Network migration safety

- Captures interface, MAC, IP, gateway, DNS, and NetworkManager connection
- Checks package health, gateway, DNS, and Domotz HTTPS before migration
- Backs up Netplan, NetworkManager, and systemd-networkd configuration
- Arms an independent systemd rollback timer
- Validates systemd-networkd, gateway, DNS, HTTPS, SSH, and Domotz afterward
- Stops before APT updates and dynavlan if required migration checks fail
- Treats a healthy DHCP IP change as a prominent warning
- Verifies rollback restores NetworkManager, original IP, and gateway

## Usage

Interactive:

```bash
sudo ./domotz-pi-provisioner-v1.1.0-beta.3.sh
```

YOLO:

```bash
sudo ./domotz-pi-provisioner-v1.1.0-beta.3.sh --yolo
```

Review a pending migration after reconnecting:

```bash
sudo domotz-pi-provisioner
```

Explicit commands remain available:

```bash
sudo domotz-pi-provisioner --commit-network-migration
sudo domotz-pi-provisioner --rollback-network-migration
```

## dynavlan integration

The beta pins dynavlan to `v0.3.0` by default and configures:

```text
RESTART_SNAPS="domotzpro-agent-publicstore"
```

The installer runs `dynavlan --version` and `dynavlan --dry-run`. The first network-changing operation remains attended:

```bash
sudo journalctl -t dynavlan -f
sudo dynavlan --boot
```

## Logs and recovery

```text
/var/log/domotz-pi-provisioner/setup.log
/var/lib/domotz-pi-provisioner/network-migration/network-backup.tar.gz
/usr/local/sbin/domotz-network-rollback
```

## License

MIT

## Netplan permissions cleanup

Beta.3 also normalizes `/lib/netplan/00-network-manager-all.yaml` to mode `0600` when that file exists, before Netplan generation and again during rollback. This addresses the overly-permissive Netplan warning observed during the beta.1 field migration.
