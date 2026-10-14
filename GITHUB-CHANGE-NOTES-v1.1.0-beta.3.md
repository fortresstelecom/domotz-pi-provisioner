# Domotz Pi Provisioner v1.1.0-beta.3

## Commit title

```text
v1.1.0-beta.3: Improve migration UX and Netplan permissions handling
```

## Commit description

```text
Promote the latest migration UX refinements to beta.3.

Changes:
- Replace rollback selection numbers with direct minute entry.
- Show valid rollback range of 3-30 minutes with a 5-minute default.
- Reprompt on invalid rollback input rather than stopping provisioning.
- Add a temporary login notice while migration confirmation is pending.
- Show interface, MAC, original IP, current IP, rollback timestamp, timezone, and remaining time after reconnect.
- Make sudo domotz-pi-provisioner automatically detect a pending migration.
- Present a simple Keep or Restore migration decision instead of starting provisioning again.
- Update pre-migration messaging so technicians only need to remember the normal sudo domotz-pi-provisioner command.
- Retain explicit commit and rollback switches for recovery and automation.
- Remove the temporary login notice after commit or successful rollback.
- Normalize /lib/netplan/00-network-manager-all.yaml to mode 0600 before Netplan generation when present.
- Normalize the same Netplan file to mode 0600 during rollback when present.
- Preserve DHCP MAC identity handling, transactional rollback, hard failure boundaries, and dynavlan dry-run behavior.
```

## Pre-release title

```text
Domotz Pi Provisioner v1.1.0-beta.3
```

## Pre-release summary

Beta.3 improves the remote technician workflow and fixes the overly-permissive Netplan configuration warning observed during live migration testing. Rollback time is entered directly in minutes, reconnecting shows the pending migration automatically, and the standard `sudo domotz-pi-provisioner` command opens a Keep/Restore decision screen.
