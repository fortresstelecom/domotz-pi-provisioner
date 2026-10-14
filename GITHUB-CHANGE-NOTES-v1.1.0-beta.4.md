# Domotz Pi Provisioner v1.1.0-beta.4

## Commit title

```text
v1.1.0-beta.4: Automate dynavlan activation and staging workflow
```

## Commit description

```text
Add automated VLAN discovery, validation, deployment, and staging controls.

Changes:
- Ask whether the Collector is currently connected to the network it will monitor.
- Explain the difference between monitored-network deployment and temporary staging.
- Default the VLAN activation prompt to No.
- Run dynavlan --dry-run automatically when immediate activation is selected.
- Display a same-line spinner and elapsed timer while dynavlan discovery is silent.
- Print the full dry-run result after discovery completes.
- Require validate: OK before applying any VLAN configuration.
- Run dynavlan --boot automatically after successful validation.
- Verify the management default interface and gateway remain unchanged.
- Display dynavlan status and configured VLAN interfaces.
- Verify the Domotz service after VLAN deployment.
- Start dynavlan.timer after successful initial activation.
- Verify the timer reports a scheduled next run.
- Add next-boot activation for devices staged before deployment.
- Add scheduled date/time activation using a systemd timer.
- Add an option to leave VLAN discovery and activation disabled.
- Disable dynavlan boot and rescan services until the selected initial activation succeeds.
- Add --discover-vlans for explicit immediate activation in YOLO mode.
- Make YOLO staging-safe by leaving VLAN discovery disabled unless --discover-vlans is supplied.
- Keep dynavlan dry-run and boot commands out of the technician's normal workflow.
- Preserve beta.3 network migration, rollback, reconnect, DHCP identity, and Netplan permissions protections.
```

## Pre-release title

```text
Domotz Pi Provisioner v1.1.0-beta.4
```

## Additional beta.4 fix

```text
- Detect the installed dynavlan version before invoking its installer.
- Skip reinstall when the requested dynavlan version is already installed.
- Preserve existing dynavlan configuration on same-version reruns.
- Upgrade dynavlan only when the installed version differs from the requested version.
- Run dynavlan --reapply after a dynavlan version upgrade before continuing.
- Avoid unnecessary timer stops, lock waits, dependency work, and file replacement on idempotent provisioner reruns.
```
