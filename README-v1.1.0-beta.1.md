# Domotz Pi Provisioner v1.1.0-beta.1

This is a **pre-release beta** for transactional migration from NetworkManager to systemd-networkd and integration with dynavlan.

Do not deploy this beta on a remote production Collector unless an out-of-band recovery path or on-site access is available.

## Milestone

v1.1 introduces automatic VLAN support through dynavlan rather than recreating its discovery, isolation, reconciliation, and rollback engine.

## Beta Behavior

### New or systemd-networkd Collector

- Skips renderer migration
- Performs package updates
- Installs a pinned dynavlan release
- Configures dynavlan to restart the Domotz Snap after subnet changes
- Runs `dynavlan --dry-run`
- Does not automatically run the first `dynavlan --boot`

### Existing NetworkManager Collector, Interactive

1. Validates dpkg/APT health.
2. Captures the management interface, IP, gateway, route, DNS, and NetworkManager connection.
3. Tests gateway, DNS, and Domotz HTTPS connectivity.
4. Prompts before renderer migration.
5. Creates a network backup.
6. Arms an independent systemd rollback timer.
7. Migrates to systemd-networkd.
8. Revalidates the management path and essential services.
9. Shows a live countdown and exact local rollback time.
10. Requires the operator to accept the changes before timeout.

If validation fails, the script stops. It does not continue into APT updates, dynavlan, or later configuration.

### Existing NetworkManager Collector, YOLO

YOLO runs the same preflight, backup, rollback, migration, and postflight checks without prompts. The migration is committed automatically only when all required postflight checks pass.

YOLO removes approval prompts. It does not bypass guardrails.

## Rollback Display

Example:

```text
Automatic rollback is ARMED.
Rollback at: October 13, 2026 at 10:17:42 PM EDT
Time remaining: 04:37
```

The rollback action is launched by systemd independently of the SSH session.

## Required Postflight Checks

- Management interface preserved
- Management IPv4 address preserved
- Default gateway preserved
- systemd-networkd active
- Gateway reachable
- DNS resolution working
- Domotz HTTPS endpoint reachable
- SSH active and listening
- Domotz service checked

## Failure Boundary

Network migration is a hard provisioning gate.

If migration or validation fails:

- The rollback timer remains armed
- The script stops
- No APT full-upgrade is performed
- dynavlan is not installed or applied
- Later Domotz configuration is not performed

## dynavlan Integration

The beta pins dynavlan to `v0.3.0` by default and configures:

```text
RESTART_SNAPS="domotzpro-agent-publicstore"
```

The installer runs:

```bash
dynavlan --version
dynavlan --dry-run
```

For safety, the first network-changing dynavlan operation remains attended:

```bash
sudo journalctl -t dynavlan -f
sudo dynavlan --boot
```

## Usage

Interactive:

```bash
sudo ./domotz-pi-provisioner-v1.1.0-beta.1.sh
```

YOLO:

```bash
sudo ./domotz-pi-provisioner-v1.1.0-beta.1.sh --yolo
```

Override rollback window:

```bash
sudo ROLLBACK_SECONDS=600 ./domotz-pi-provisioner-v1.1.0-beta.1.sh
```

## Beta Limitations

- Supports NetworkManager connections using IPv4 `auto` or `manual` methods.
- Does not automatically perform the first `dynavlan --boot`.
- Must be tested on non-critical Collectors before broad deployment.
- A management-stack migration can still interrupt remote access despite rollback protection.
- The health endpoint is configurable through `HEALTHCHECK_URL`.

## Logs and Recovery

Provisioner log:

```text
/var/log/domotz-pi-provisioner/setup.log
```

Network backup:

```text
/var/lib/domotz-pi-provisioner/network-migration/network-backup.tar.gz
```

Rollback script:

```text
/usr/local/sbin/domotz-network-rollback
```

Manually invoke rollback from console:

```bash
sudo /usr/local/sbin/domotz-network-rollback
```

## Version History

### v1.1.0-beta.1

- Added transactional NetworkManager-to-systemd-networkd migration
- Added independent five-minute systemd rollback timer
- Added live countdown and exact rollback timestamp with timezone and AM/PM
- Added manual Interactive commit
- Added automatic YOLO commit after successful health validation
- Added hard stop on migration failure
- Added pinned dynavlan installation and Domotz restart integration
- Added dynavlan dry-run validation

## License

MIT
