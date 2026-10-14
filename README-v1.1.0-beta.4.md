# Domotz Pi Provisioner v1.1.0-beta.4

Beta.4 automates the dynavlan preview, initial VLAN apply, validation, and rescan-timer setup while supporting Collectors staged away from the network they will monitor.

## VLAN deployment question

The provisioner explains the purpose of discovery and asks:

```text
Is this device currently connected to the network it will be monitoring?

  [Y] Yes - discover, validate, and configure VLANs now
  [N] No  - the device is currently being staged

Configure VLANs now? [y/N]:
```

No is the default.

## Connected to the monitored network

When Yes is selected, the provisioner:

1. Runs `dynavlan --dry-run` automatically.
2. Shows a spinner and elapsed time while discovery is silent.
3. Prints the full dry-run output.
4. Requires `validate: OK`.
5. Runs `dynavlan --boot` automatically.
6. Verifies the management default interface and gateway are preserved.
7. Displays dynavlan status and VLAN leases.
8. Verifies Domotz remains active.
9. Starts `dynavlan.timer`.
10. Confirms the timer has a scheduled next run.

The technician does not need to run dynavlan commands manually.

## Staging options

When No is selected, beta.4 offers:

- **Next boot:** a one-time activation service performs dry-run validation, applies VLANs, and starts the rescan timer after the device boots on the monitored network.
- **Scheduled date and time:** a systemd timer performs the same activation later using the device's local time.
- **Leave disabled:** dynavlan remains installed but automatic discovery and VLAN application stay disabled.

The default staging selection is Leave disabled.

## YOLO

YOLO treats the device as staged by default and leaves discovery disabled unless explicitly requested:

```bash
sudo domotz-pi-provisioner --yolo --discover-vlans
```

## Existing beta features

- Transactional NetworkManager-to-systemd-networkd migration
- Configurable rollback window
- MAC/IP recovery guidance
- Automatic rollback timer
- Reconnect login notice and Keep/Restore menu
- Netplan permissions correction
- DHCP MAC identity handling
- Hard stop before package or dynavlan work when migration fails

## Logs

```text
/var/log/domotz-pi-provisioner/setup.log
/var/log/domotz-pi-provisioner/dynavlan-discovery.log
```

## License

MIT
