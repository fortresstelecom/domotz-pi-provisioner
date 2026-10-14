# Domotz Pi Provisioner v1.1.0-beta.2

This pre-release beta adds configurable rollback windows, stable MAC identification, improved DHCP migration behavior, and stricter rollback validation to the v1.1 dynavlan milestone.

> Use only on non-critical Collectors with console, on-site, or other out-of-band recovery access.

## Changes from beta.1

- Interactive rollback choices: 3, 5, 10, 15, or custom 3-30 minutes
- Five-minute YOLO default retained through `ROLLBACK_SECONDS=300`
- MAC address displayed before, during, and after migration
- Explicit warning that DHCP addressing may change
- Reconnect instructions using `--commit-network-migration`
- `dhcp-identifier: mac` added to generated DHCP Netplan configuration
- DHCP IP change is a prominent warning when gateway, DNS, HTTPS, SSH, and renderer checks pass
- Rollback now verifies NetworkManager active, systemd-networkd inactive, original IP restored, and gateway reachable
- Rollback logs `STARTED`, `VALIDATED`, `COMPLETE`, or `INCOMPLETE`
- Transient rollback units are explicitly cleaned up
- Netplan permission warning for `/lib/netplan/00-network-manager-all.yaml` is corrected when that file exists

## Interactive workflow

1. Validate package and connectivity health.
2. Capture management interface, MAC, address, gateway, NetworkManager connection, and DNS.
3. Select a rollback window.
4. Review the IP-change warning and recovery identity.
5. Back up all networking configuration.
6. Arm the independent systemd rollback.
7. Migrate to systemd-networkd.
8. Validate management routing and services.
9. Commit the configuration before the countdown expires.

Example warning:

```text
IMPORTANT: The DHCP IP address MAY CHANGE during this migration.

Interface:       eth0
MAC address:     dc:a6:32:xx:xx:xx
Current IP:      192.168.20.85/24
Default gateway: 192.168.20.1
Rollback window: 10 minutes
```

If SSH reconnects on another address, commit from the new session:

```bash
sudo domotz-pi-provisioner --commit-network-migration
```

Force immediate rollback from a console or active session:

```bash
sudo domotz-pi-provisioner --rollback-network-migration
```

## YOLO workflow

YOLO uses the configured `ROLLBACK_SECONDS`, defaults to five minutes, and automatically commits only after required postflight checks pass.

```bash
sudo ROLLBACK_SECONDS=600 ./domotz-pi-provisioner-v1.1.0-beta.2.sh --yolo
```

## Failure boundary

Network migration remains a hard gate. If migration or required validation fails:

- The rollback remains armed
- The provisioner stops
- No APT full-upgrade runs
- dynavlan is not installed or applied
- Later configuration is not attempted

## dynavlan integration

The beta pins dynavlan to `v0.3.0` by default and sets:

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

## Usage

Interactive:

```bash
sudo ./domotz-pi-provisioner-v1.1.0-beta.2.sh
```

YOLO:

```bash
sudo ./domotz-pi-provisioner-v1.1.0-beta.2.sh --yolo
```

## Version history

### v1.1.0-beta.2

- Added selectable rollback windows
- Added MAC/ARP/DHCP recovery guidance
- Added reconnect-time commit and explicit rollback commands
- Added DHCP MAC identifier
- Improved rollback renderer cleanup and validation
- Changed a healthy DHCP address change from fatal failure to prominent warning

### v1.1.0-beta.1

- Added transactional renderer migration
- Added automatic rollback and health validation
- Added initial pinned dynavlan integration

## License

MIT
