# Commit title

```text
v1.1.0-beta.4: Handle networks without tagged VLAN trunks
```

# Commit description

```text
Treat a successful dynavlan discovery with no tagged VLAN trunk as a valid no-change result.

Changes:
- Detect dynavlan dry-run output indicating that no tagged VLAN trunk was found.
- Report the no-trunk condition as informational instead of failing validation.
- Skip dynavlan --boot when there are no VLAN interfaces to configure.
- Confirm that management networking remains unchanged.
- Start and verify dynavlan.timer so future tagged VLANs can still be discovered automatically.
- Record the final activation state as no-tagged-vlans.
- Continue to require validate: OK when tagged VLANs are detected.
- Preserve durable systemd-based VLAN application when tagged VLANs are present.
- Preserve SSH-disconnect resilience, route validation, Domotz checks, and timer verification.
```
