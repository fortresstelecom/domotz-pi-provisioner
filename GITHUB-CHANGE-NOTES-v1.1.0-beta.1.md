# Domotz Pi Provisioner v1.1.0-beta.1

## Commit title

```text
v1.1.0-beta.1: Add transactional network migration and dynavlan integration
```

## Commit description

```text
Introduce the v1.1 VLAN milestone as a pre-release beta.

Changes:
- Add NetworkManager-to-systemd-networkd migration for existing collectors.
- Add management interface, address, gateway, route, DNS, and connectivity preflight.
- Back up NetworkManager, netplan, and systemd-networkd configuration before migration.
- Arm an independent systemd rollback timer before applying network changes.
- Display the exact rollback date and time using local timezone and AM/PM formatting.
- Display a live MM:SS rollback countdown during Interactive confirmation.
- Require manual confirmation to commit Interactive migrations.
- Automatically commit YOLO migrations only after all required postflight checks pass.
- Preserve the management interface, IPv4 address, and default gateway as validation invariants.
- Validate gateway, DNS, Domotz HTTPS, SSH, systemd-networkd, and Domotz service state.
- Stop provisioning when migration or postflight validation fails.
- Prevent APT updates, dynavlan installation, and later configuration after migration failure.
- Install pinned dynavlan v0.3.0.
- Configure dynavlan to restart the Domotz Snap after network changes.
- Run dynavlan version and dry-run checks.
- Leave the first dynavlan --boot operation attended during beta testing.
```

## Pre-release title

```text
Domotz Pi Provisioner v1.1.0-beta.1
```

## Pre-release notes

This beta introduces transactional migration from NetworkManager to systemd-networkd and the first dynavlan integration for automatic tagged-VLAN discovery.

### Safety model

- Five-minute automatic rollback by default
- Exact rollback timestamp and live countdown
- Manual commit in Interactive mode
- Automatic commit in YOLO only after successful validation
- Hard stop before package updates or dynavlan when migration fails
- Independent systemd rollback that survives SSH session loss

### Testing warning

Use this beta only on non-critical collectors with console, on-site, or other out-of-band recovery access. The first dynavlan apply remains intentionally attended.
