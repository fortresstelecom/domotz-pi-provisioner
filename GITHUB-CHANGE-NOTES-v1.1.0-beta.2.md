# Domotz Pi Provisioner v1.1.0-beta.2

## Commit title

```text
v1.1.0-beta.2: Improve migration rollback and DHCP recovery workflow
```

## Commit description

```text
Refine the v1.1 network migration beta based on the first live rollback test.

Changes:
- Add Interactive rollback-window choices for 3, 5, 10, 15, or custom 3-30 minutes.
- Retain configurable promptless rollback timing for YOLO.
- Capture and display the management interface MAC address.
- Warn that the DHCP address may change during renderer migration.
- Print interface, MAC, current IP, gateway, and rollback window before approval.
- Add operator guidance for locating the Collector in switch, firewall, DHCP, and ARP tables.
- Add --commit-network-migration for committing after reconnecting on a new address.
- Add --rollback-network-migration for immediate manual recovery.
- Add dhcp-identifier: mac to the generated networkd Netplan configuration.
- Change a healthy DHCP address change from a fatal error to a prominent warning.
- Keep route, gateway, DNS, HTTPS, SSH, and renderer failures fatal.
- Strengthen rollback validation to require NetworkManager active and systemd-networkd inactive.
- Verify restoration of the original management address and gateway.
- Add explicit rollback STARTED, VALIDATED, COMPLETE, and INCOMPLETE log states.
- Explicitly clean up transient rollback timer and service units.
- Correct open permissions on the Netplan NetworkManager policy file when present.
- Preserve the hard stop before APT updates and dynavlan after migration failure.
```

## Pre-release title

```text
Domotz Pi Provisioner v1.1.0-beta.2
```

## Pre-release notes

Beta.2 incorporates findings from the first live NetworkManager-to-systemd-networkd migration and automatic rollback test.

### Highlights

- Technician-selectable rollback safety window
- Exact rollback timestamp and live countdown
- Stable MAC identity throughout address changes
- Reconnect-time commit command
- Immediate manual rollback command
- Improved DHCP identity handling
- Stronger renderer cleanup after rollback
- Healthy IP changes reported as warnings instead of unconditional migration failures

### Testing warning

Use only on non-critical Collectors with console, on-site, or other out-of-band recovery access. The first dynavlan apply remains intentionally attended.
