#!/usr/bin/env bash
# Domotz Pi Provisioner v1.0.4
# License: MIT
set -u
set -o pipefail

VERSION="1.0.4"
DOMOTZ="domotzpro-agent-publicstore"
REBOOT_TIME="${REBOOT_TIME:-02:00}"
RESTART_DOMOTZ="${RESTART_DOMOTZ:-auto}"
MIN_FREE_ROOT_MB="${MIN_FREE_ROOT_MB:-2048}"
LOG_DIR="/var/log/domotz-pi-provisioner"
LOG_FILE="$LOG_DIR/setup.log"
BACKUP_DIR="/var/backups/domotz-pi-provisioner"
AUTO_POLICY="/etc/apt/apt.conf.d/20auto-upgrades"
LOCAL_POLICY="/etc/apt/apt.conf.d/52-domotz-pi-provisioner"
LAUNCHER="/usr/local/sbin/domotz-pi-provisioner"
MARKER="/var/lib/domotz-pi-provisioner/rerun-required"
MOTD="/etc/motd.d/99-domotz-pi-provisioner"
ERRORS=0; WARNINGS=0
EXISTING=false; INSTALLED=false; RESTARTED=false; REBOOT_REQUIRED=false

if [[ -t 1 ]]; then G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[0;34m'; X='\033[0m'; else G=''; R=''; Y=''; B=''; X=''; fi
pass(){ echo -e "${G}[PASS]${X} $*"; }
fail(){ echo -e "${R}[FAIL]${X} $*"; ERRORS=$((ERRORS+1)); }
warn(){ echo -e "${Y}[WARN]${X} $*"; WARNINGS=$((WARNINGS+1)); }
info(){ echo -e "${B}[INFO]${X} $*"; }
section(){ echo; printf '%s\n%s\n%s\n' '==============================================================================' "$*" '=============================================================================='; }
has(){ command -v "$1" >/dev/null 2>&1; }
backup_once(){ local f="$1" n; [[ -e "$f" ]] || return 0; n="$(echo "$f"|sed 's#^/##;s#/#_#g')"; [[ -e "$BACKUP_DIR/$n.original" ]] || cp -a "$f" "$BACKUP_DIR/$n.original"; }
pending(){ apt list --upgradable 2>/dev/null | awk 'NR>1{n++}END{print n+0}'; }

[[ $EUID -eq 0 ]] || { echo "Run with sudo."; exit 1; }
case "$RESTART_DOMOTZ" in auto|true|false) ;; *) echo "RESTART_DOMOTZ must be auto, true, or false"; exit 1;; esac
[[ "$REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "Invalid REBOOT_TIME"; exit 1; }
[[ "$MIN_FREE_ROOT_MB" =~ ^[0-9]+$ ]] || { echo "MIN_FREE_ROOT_MB must be numeric"; exit 1; }
mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$(dirname "$MARKER")" /etc/motd.d
chmod 750 "$LOG_DIR" "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

section "PERSISTENT PROVISIONER COMMAND"
SELF="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
if [[ -f "$SELF" ]]; then
  install -m 0755 "$SELF" "$LAUNCHER"
  pass "Installed persistent command: $LAUNCHER"
else
  fail "Unable to locate running script."
  exit 1
fi

section "DOMOTZ PI PROVISIONER"
info "Version: $VERSION"
info "Hostname: $(hostname)"
info "Started: $(date --iso-8601=seconds 2>/dev/null || date)"

section "OPERATING SYSTEM VALIDATION"
if [[ -r /etc/os-release ]]; then . /etc/os-release; info "Operating system: ${PRETTY_NAME:-Unknown}"; fi
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"; info "Architecture: $ARCH"
if [[ -r /proc/device-tree/model ]]; then MODEL="$(tr -d '\0' </proc/device-tree/model)"; info "Hardware model: $MODEL"; [[ "$MODEL" == *"Raspberry Pi"* ]] && pass "Raspberry Pi detected." || warn "Hardware does not identify as Raspberry Pi."; fi
has apt-get || { fail "apt-get unavailable."; exit 1; }
has systemctl || { fail "systemctl unavailable."; exit 1; }
getent hosts deb.debian.org >/dev/null 2>&1 && pass "DNS resolution works." || { fail "DNS resolution failed."; exit 1; }

section "PRE-UPGRADE PACKAGE HEALTH"
AUDIT="$(dpkg --audit 2>/dev/null || true)"; [[ -z "$AUDIT" ]] && pass "dpkg audit clean." || { fail "dpkg reports incomplete operations."; echo "$AUDIT"; exit 1; }
apt-get check >/dev/null 2>&1 && pass "APT dependency check passed." || { fail "APT dependency check failed."; exit 1; }

section "APT METADATA REFRESH"
apt-get update && pass "APT metadata refreshed." || { fail "apt-get update failed."; exit 1; }
PENDING_BEFORE="$(pending)"; info "Pending updates before upgrade: $PENDING_BEFORE"

section "DISK SPACE PREFLIGHT"
FREE_KB="$(df -Pk / | awk 'NR==2{print $4}')"; FREE_MB=$((FREE_KB/1024)); FREE_GB="$(awk -v k="$FREE_KB" 'BEGIN{printf "%.2f",k/1048576}')"
info "Root free space: $FREE_GB GiB ($FREE_MB MiB)."
info "Required minimum: $MIN_FREE_ROOT_MB MiB."
[[ "$FREE_MB" -ge "$MIN_FREE_ROOT_MB" ]] && pass "Disk-space preflight passed." || { fail "Insufficient free disk space."; exit 1; }

section "INITIAL SYSTEM UPDATE"
if [[ "$PENDING_BEFORE" -gt 0 ]]; then
  info "Installing all available updates before provisioning."
  DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confold" full-upgrade && pass "Full system update completed." || { fail "Full system update failed."; exit 1; }
else
  pass "System is already up to date."
fi

section "POST-UPGRADE PACKAGE HEALTH"
AUDIT="$(dpkg --audit 2>/dev/null || true)"; [[ -z "$AUDIT" ]] && pass "dpkg audit clean." || { fail "dpkg reports incomplete operations."; echo "$AUDIT"; }
apt-get check >/dev/null 2>&1 && pass "APT dependency check passed." || fail "APT dependency check failed."
PENDING_AFTER="$(pending)"; [[ "$PENDING_AFTER" -eq 0 ]] && pass "No updates remain pending." || warn "$PENDING_AFTER update(s) remain pending."

section "REQUIRED PACKAGES"
DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confold" snapd unattended-upgrades ca-certificates && pass "Required packages installed." || { fail "Required package installation failed."; exit 1; }
systemctl enable --now snapd.socket >/dev/null 2>&1 && pass "snapd.socket enabled." || fail "Unable to enable snapd.socket."
[[ -e /snap || ! -d /var/lib/snapd/snap ]] || ln -s /var/lib/snapd/snap /snap

section "DOMOTZ COLLECTOR"
if snap list "$DOMOTZ" >/dev/null 2>&1; then EXISTING=true; pass "Existing Domotz installation preserved."; else snap install "$DOMOTZ" && { INSTALLED=true; pass "Domotz installed."; } || fail "Domotz installation failed."; fi

section "DOMOTZ SNAP INTERFACES"
for i in firewall-control network-observe raw-usb shutdown system-observe; do p="$DOMOTZ:$i"; snap connections "$DOMOTZ" 2>/dev/null | awk -v t="$p" '$2==t&&$3!="-"{f=1}END{exit !f}' && pass "$p is connected." || { snap connect "$p" && pass "$p connected." || fail "Unable to connect $p."; }; done

section "TUN SUPPORT"
touch /etc/modules; grep -Eq '^[[:space:]]*tun([[:space:]]*#.*)?$' /etc/modules || printf '\ntun\n' >>/etc/modules
modprobe tun && pass "TUN loaded." || fail "Unable to load TUN."
[[ -c /dev/net/tun ]] && pass "/dev/net/tun available." || warn "/dev/net/tun unavailable."

section "DOMOTZ COMPATIBILITY SETTINGS"
if [[ -f /etc/ld.so.preload ]]; then backup_once /etc/ld.so.preload; sed -Ei '/^[[:space:]]*[^#].*libarmmem.*\.so[[:space:]]*$/ s/^([[:space:]]*)/\1# Domotz Pi Provisioner: /' /etc/ld.so.preload; fi
if [[ -f /etc/ssh/ssh_config ]]; then backup_once /etc/ssh/ssh_config; sed -Ei '/^[[:space:]]*Include[[:space:]]+\/etc\/ssh\/ssh_config\.d\/\*\.conf[[:space:]]*$/ s/^([[:space:]]*)/\1# Domotz Pi Provisioner: /' /etc/ssh/ssh_config; ssh -G localhost >/dev/null 2>&1 && pass "SSH client configuration parses." || warn "SSH client configuration check failed."; fi

section "DOMOTZ RESTART POLICY"
DO_RESTART=false; [[ "$RESTART_DOMOTZ" == true || ( "$RESTART_DOMOTZ" == auto && "$INSTALLED" == true ) ]] && DO_RESTART=true
if [[ "$DO_RESTART" == true ]]; then snap restart "$DOMOTZ" && { RESTARTED=true; pass "Domotz restarted."; } || fail "Domotz restart failed."; sleep 3; else pass "Existing Domotz restart skipped to preserve remote access."; fi

section "DOMOTZ SERVICE VALIDATION"
SERVICES="$(snap services "$DOMOTZ" 2>/dev/null || true)"; printf '%s\n' "$SERVICES" | awk 'NR>1&&$3=="active"{f=1}END{exit !f}' && pass "At least one Domotz service is active." || { fail "No active Domotz service detected."; echo "$SERVICES"; }

section "AUTOMATIC UPDATE POLICY"
backup_once "$AUTO_POLICY"; backup_once "$LOCAL_POLICY"
cat >"$AUTO_POLICY" <<'EOF'
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat >"$LOCAL_POLICY" <<EOF
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
 "origin=Debian,codename=\${distro_codename},label=Debian";
 "origin=Debian,codename=\${distro_codename}-updates";
 "origin=Debian,codename=\${distro_codename},label=Debian-Security";
 "origin=Debian,codename=\${distro_codename}-security,label=Debian-Security";
 "origin=Raspberry Pi Foundation";
};
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "$REBOOT_TIME";
EOF
chmod 644 "$AUTO_POLICY" "$LOCAL_POLICY"; pass "Automatic update policies written."
apt-config dump >/dev/null 2>&1 && pass "APT configuration parses." || fail "APT configuration parsing failed."
for t in apt-daily.timer apt-daily-upgrade.timer; do systemctl enable --now "$t" >/dev/null 2>&1 && pass "$t enabled." || fail "Unable to enable $t."; done

section "REBOOT STATUS"
if [[ -f /var/run/reboot-required ]]; then
  REBOOT_REQUIRED=true; warn "System updates require a reboot."
  touch "$MARKER"
  cat >"$MOTD" <<'EOF'

*** DOMOTZ PI PROVISIONING INCOMPLETE ***
A reboot was required during provisioning.
Rerun the provisioner to complete final validation.

Copy/paste:
sudo domotz-pi-provisioner

EOF
  chmod 644 "$MOTD"; pass "Installed post-reboot login reminder."
else
  pass "No reboot required."
  if [[ -f "$MARKER" ]]; then rm -f "$MARKER" "$MOTD"; pass "Post-reboot validation complete; login reminder removed."; fi
fi

section "FINAL DEPLOYMENT REPORT"
printf 'Version:             %s\nHostname:            %s\nArchitecture:        %s\nUpdates before:      %s\nRoot free preflight: %s MiB\nUpdates remaining:   %s\nExisting collector:  %s\nInstalled this run:  %s\nDomotz restarted:    %s\nReboot required:     %s\nSetup log:           %s\nErrors:              %s\nWarnings:            %s\n' "$VERSION" "$(hostname)" "$ARCH" "$PENDING_BEFORE" "$FREE_MB" "$PENDING_AFTER" "$EXISTING" "$INSTALLED" "$RESTARTED" "$REBOOT_REQUIRED" "$LOG_FILE" "$ERRORS" "$WARNINGS"

if [[ "$ERRORS" -eq 0 ]]; then
  pass "DOMOTZ PI PROVISIONER VALIDATION PASSED"
  if [[ "$REBOOT_REQUIRED" == true ]]; then
    if [[ -t 0 ]]; then
      while true; do read -r -p "Reboot required. Reboot now? [y/N]: " a; case "$a" in [Yy]|[Yy][Ee][Ss]) info "Rebooting now."; sync; systemctl reboot; exit 0;; [Nn]|[Nn][Oo]|"") info "Reboot deferred."; break;; *) echo "Please answer Y or N.";; esac; done
    else warn "Reboot required; noninteractive session did not reboot automatically."; fi
  fi
  exit 0
else
  fail "DOMOTZ PI PROVISIONER VALIDATION FAILED"
  exit 1
fi
