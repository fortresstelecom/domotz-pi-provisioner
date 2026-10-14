# Domotz Pi Provisioner v1.1.0-beta.4

## No tagged VLAN trunk behavior

A successful dynavlan dry run that reports `no trunks detected; would change nothing` is treated as a valid no-change result. The provisioner does not run `dynavlan --boot`, reports that management networking remains unchanged, starts and verifies `dynavlan.timer`, and records the activation state as `no-tagged-vlans`.

When tagged VLANs are detected, beta.4 still requires `validate: OK` and runs the VLAN application plus post-apply checks in a durable systemd service so the workflow continues if SSH disconnects.
