#!/usr/bin/env bash
# Domotz Pi Provisioner v1.0.3
# License: MIT
#
# Provisioning order:
#   1. Validate the host and package manager
#   2. Refresh APT metadata
#   3. Fully update the operating system
#   4. Install/configure Domotz prerequisites and Collector
#   5. Configure unattended updates
#   6. Validate the completed deployment

set -u
set -o pipefail

SCRIPT_VERSION="1.0.3"
DOMOTZ_SNAP="domotzpro-agent-publicstore"
AUTO_POLICY="/etc/apt/apt.conf.d/20auto-upgrades"
LOCAL_POLICY="/etc/apt/apt.conf.d/52-domotz-pi-provisioner"
MODULES_FILE="/etc/modules"
LD_PRELOAD_FILE="/etc/ld.so.preload"
SSH_CONFIG_FILE="/etc/ssh/ssh_config"
REBOOT_TIME="${REBOOT_TIME:-02:00}"
RESTART_DOMOTZ="${RESTART_DOMOTZ:-auto}"
LOG_DIR="/var/log/domotz-pi-provisioner"
LOG_FILE="$LOG_DIR/setup.log"
BACKUP_DIR="/var/backups/domotz-pi-provisioner"
ERRORS=0
WARNINGS=0
DOMOTZ_ALREADY_INSTALLED=false
DOMOTZ_INSTALLED_THIS_RUN=false
COMPATIBILITY_CHANGED=false
SHOULD_RESTART=false
PENDING_BEFORE=0
PENDING_AFTER=0

if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

pass(){ echo -e "${GREEN}[PASS]${NC} $*"; }
fail(){ echo -e "${RED}[FAIL]${NC} $*"; ERRORS=$((ERRORS+1)); }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; WARNINGS=$((WARNINGS+1)); }
info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
section(){ echo; echo -e "${BOLD}==============================================================================${NC}"; echo -e "${BOLD}$*${NC}"; echo -e "${BOLD}==============================================================================${NC}"; }
has(){ command -v "$1" >/dev/null 2>&1; }

backup_once(){
  local file="$1" backup_name
  [[ -e "$file" ]] || return 0
  backup_name="$(echo "$file" | sed 's#^/##;s#/#_#g')"
  if [[ ! -e "$BACKUP_DIR/$backup_name.original" ]]; then
    cp -a "$file" "$BACKUP_DIR/$backup_name.original"
    pass "Created original backup of $file."
  else
    info "Original backup already exists for $file."
  fi
}

count_pending_updates(){
  apt list --upgradable 2>/dev/null | awk 'NR>1 {count++} END {print count+0}'
}

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo ./$0"; exit 1; }
case "$RESTART_DOMOTZ" in auto|true|false) ;; *) echo "RESTART_DOMOTZ must be auto, true, or false"; exit 1;; esac
[[ "$REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "Invalid REBOOT_TIME: $REBOOT_TIME"; exit 1; }

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
chmod 750 "$LOG_DIR" "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

section "DOMOTZ PI PROVISIONER"
info "Version: $SCRIPT_VERSION"
info "Hostname: $(hostname)"
info "Started: $(date --iso-8601=seconds 2>/dev/null || date)"
info "Reboot window: $REBOOT_TIME local time"
info "Domotz restart policy: $RESTART_DOMOTZ"
info "Setup log: $LOG_FILE"

section "OPERATING SYSTEM VALIDATION"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  info "Operating system: ${PRETTY_NAME:-Unknown}"
  case "${ID:-}" in
    debian|raspbian) pass "Supported Debian-family OS detected." ;;
    *) warn "OS does not identify as Debian or Raspbian." ;;
  esac
fi

ARCHITECTURE="$(dpkg --print-architecture 2>/dev/null || uname -m)"
info "Architecture: $ARCHITECTURE"

if [[ -r /proc/device-tree/model ]]; then
  MODEL="$(tr -d '\0' < /proc/device-tree/model)"
  info "Hardware model: $MODEL"
  [[ "$MODEL" == *"Raspberry Pi"* ]] && pass "Raspberry Pi hardware detected." || warn "Hardware does not identify as Raspberry Pi."
fi

has apt-get || { fail "apt-get unavailable."; exit 1; }
has systemctl || { fail "systemctl unavailable."; exit 1; }

section "NETWORK AND TIME VALIDATION"
getent hosts deb.debian.org >/dev/null 2>&1 && pass "DNS resolution is working." || fail "Unable to resolve deb.debian.org."
getent hosts archive.raspberrypi.com >/dev/null 2>&1 && pass "Raspberry Pi repository DNS works." || warn "Unable to resolve archive.raspberrypi.com."

if has timedatectl; then
  TIMEZONE="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  TIME_SYNC="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  info "System timezone: ${TIMEZONE:-Unknown}"
  [[ "$TIME_SYNC" == yes ]] && pass "System clock reports synchronized." || warn "System clock does not report NTP synchronization."
fi

section "PRE-UPGRADE PACKAGE HEALTH"
DPKG_AUDIT="$(dpkg --audit 2>/dev/null || true)"
if [[ -z "$DPKG_AUDIT" ]]; then
  pass "dpkg reports no incomplete package operations."
else
  fail "dpkg reports incomplete package operations:"
  echo "$DPKG_AUDIT"
  exit 1
fi

apt-get check >/dev/null 2>&1 && pass "APT dependency check passed." || { fail "APT dependency check failed."; exit 1; }

section "APT METADATA REFRESH"
apt-get update && pass "APT metadata refreshed." || { fail "apt-get update failed."; exit 1; }

PENDING_BEFORE="$(count_pending_updates)"
info "Pending package updates before initial upgrade: $PENDING_BEFORE"

section "INITIAL SYSTEM UPDATE"
if [[ "$PENDING_BEFORE" -gt 0 ]]; then
  info "Installing all currently available updates before provisioning."
  info "APT output below provides live download and installation progress."

  if DEBIAN_FRONTEND=noninteractive apt-get -y \
      -o Dpkg::Options::="--force-confold" \
      full-upgrade; then
    pass "Initial full system update completed successfully."
  else
    fail "Initial full system update failed."
    exit 1
  fi
else
  pass "System is already fully up to date."
fi

section "POST-UPGRADE PACKAGE HEALTH"
DPKG_AUDIT="$(dpkg --audit 2>/dev/null || true)"
if [[ -z "$DPKG_AUDIT" ]]; then
  pass "dpkg reports no incomplete package operations."
else
  fail "dpkg reports incomplete package operations after the update:"
  echo "$DPKG_AUDIT"
fi

apt-get check >/dev/null 2>&1 && pass "APT dependency check passed after the update." || fail "APT dependency check failed after the update."

PENDING_AFTER="$(count_pending_updates)"
if [[ "$PENDING_AFTER" -eq 0 ]]; then
  pass "No package updates remain pending."
else
  warn "$PENDING_AFTER package update(s) remain pending after full-upgrade."
  info "Review holds, phased updates, repository policy, or dependency constraints."
fi

section "REQUIRED PACKAGE INSTALLATION"
if DEBIAN_FRONTEND=noninteractive apt-get install -y \
    -o Dpkg::Options::="--force-confold" \
    snapd unattended-upgrades ca-certificates; then
  pass "Required packages are installed."
else
  fail "Failed to install one or more required packages."
  exit 1
fi

section "SNAP SERVICE"
systemctl daemon-reload
systemctl enable --now snapd.socket >/dev/null 2>&1 && pass "snapd.socket enabled." || fail "Unable to enable snapd.socket."

if [[ ! -e /snap && -d /var/lib/snapd/snap ]]; then
  ln -s /var/lib/snapd/snap /snap
  pass "Created /snap compatibility link."
fi

has snap || { fail "snap command unavailable."; exit 1; }

section "DOMOTZ COLLECTOR"
if snap list "$DOMOTZ_SNAP" >/dev/null 2>&1; then
  DOMOTZ_ALREADY_INSTALLED=true
  pass "Existing Domotz installation detected and will be preserved."
else
  if snap install "$DOMOTZ_SNAP"; then
    DOMOTZ_INSTALLED_THIS_RUN=true
    pass "Domotz installed."
  else
    fail "Domotz installation failed."
  fi
fi

section "DOMOTZ SNAP INTERFACES"
for interface in firewall-control network-observe raw-usb shutdown system-observe; do
  plug="$DOMOTZ_SNAP:$interface"
  if snap connections "$DOMOTZ_SNAP" 2>/dev/null | awk -v target="$plug" '$2==target && $3!="-"{found=1} END{exit !found}'; then
    pass "$plug is connected."
  else
    snap connect "$plug" && pass "$plug connected." || fail "Unable to connect $plug."
  fi
done

section "TUN SUPPORT"
touch "$MODULES_FILE"
if grep -Eq '^[[:space:]]*tun([[:space:]]*#.*)?$' "$MODULES_FILE"; then
  pass "TUN is configured to load at boot."
else
  printf '\ntun\n' >> "$MODULES_FILE"
  pass "Added TUN to $MODULES_FILE."
fi

modprobe tun && pass "TUN loaded." || fail "Unable to load TUN."
[[ -c /dev/net/tun ]] && pass "/dev/net/tun available." || warn "/dev/net/tun unavailable."

section "DOMOTZ COMPATIBILITY SETTINGS"
if [[ -f "$LD_PRELOAD_FILE" ]]; then
  backup_once "$LD_PRELOAD_FILE"
  if grep -Eq '^[[:space:]]*[^#].*libarmmem.*\.so[[:space:]]*$' "$LD_PRELOAD_FILE"; then
    sed -Ei '/^[[:space:]]*[^#].*libarmmem.*\.so[[:space:]]*$/ s/^([[:space:]]*)/\1# Domotz Pi Provisioner: /' "$LD_PRELOAD_FILE"
    COMPATIBILITY_CHANGED=true
    pass "Disabled the active libarmmem preload entry."
  elif grep -Eq '^[[:space:]]*#.*libarmmem.*\.so' "$LD_PRELOAD_FILE"; then
    pass "libarmmem preload entry is already disabled."
  else
    info "No libarmmem preload entry found; no change required."
  fi
else
  info "$LD_PRELOAD_FILE does not exist; no change required."
fi

if [[ -f "$SSH_CONFIG_FILE" ]]; then
  backup_once "$SSH_CONFIG_FILE"
  if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/ssh_config\.d/\*\.conf[[:space:]]*$' "$SSH_CONFIG_FILE"; then
    sed -Ei '/^[[:space:]]*Include[[:space:]]+\/etc\/ssh\/ssh_config\.d\/\*\.conf[[:space:]]*$/ s/^([[:space:]]*)/\1# Domotz Pi Provisioner: /' "$SSH_CONFIG_FILE"
    COMPATIBILITY_CHANGED=true
    pass "Disabled the global SSH client Include directive."
  elif grep -Eq '^[[:space:]]*#.*Include[[:space:]]+/etc/ssh/ssh_config\.d/\*\.conf' "$SSH_CONFIG_FILE"; then
    pass "Global SSH client Include directive is already disabled."
  else
    info "Specified SSH Include directive not found; no change required."
  fi
else
  warn "$SSH_CONFIG_FILE does not exist."
fi

if has ssh; then
  ssh -G localhost >/dev/null 2>&1 && pass "SSH client configuration parses successfully." || warn "SSH client configuration validation returned an error."
fi

section "DOMOTZ RESTART POLICY"
case "$RESTART_DOMOTZ" in
  true) SHOULD_RESTART=true ;;
  false) SHOULD_RESTART=false ;;
  auto) [[ "$DOMOTZ_INSTALLED_THIS_RUN" == true ]] && SHOULD_RESTART=true ;;
esac

if [[ "$SHOULD_RESTART" == true ]]; then
  [[ "$DOMOTZ_ALREADY_INSTALLED" == true ]] && warn "Restarting an existing Collector may interrupt Domotz Remote Access."
  snap restart "$DOMOTZ_SNAP" && pass "Domotz restart completed." || fail "Domotz restart failed."
  sleep 3
else
  if [[ "$DOMOTZ_ALREADY_INSTALLED" == true ]]; then
    pass "Existing Domotz Collector restart skipped to preserve remote access."
    [[ "$COMPATIBILITY_CHANGED" == true ]] && warn "Compatibility settings changed; perform a controlled restart later if required."
  else
    warn "Domotz restart skipped by RESTART_DOMOTZ=false."
  fi
fi

section "DOMOTZ SERVICE VALIDATION"
if snap list "$DOMOTZ_SNAP" >/dev/null 2>&1; then
  DOMOTZ_SERVICES="$(snap services "$DOMOTZ_SNAP" 2>/dev/null || true)"
  if printf '%s\n' "$DOMOTZ_SERVICES" | awk 'NR>1 && $3=="active"{found=1} END{exit !found}'; then
    pass "At least one Domotz service is active."
  else
    fail "No active Domotz service detected."
    printf '%s\n' "$DOMOTZ_SERVICES"
    if [[ "$DOMOTZ_ALREADY_INSTALLED" == true ]]; then
      warn "Existing Collector service state was not changed automatically."
      warn "Review service output and logs before starting or restarting Domotz."
    fi
  fi
fi

section "AUTOMATIC UPDATE POLICY"
backup_once "$AUTO_POLICY"
backup_once "$LOCAL_POLICY"

cat > "$AUTO_POLICY" <<'EOF'
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > "$LOCAL_POLICY" <<EOF
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

chmod 644 "$AUTO_POLICY" "$LOCAL_POLICY"
pass "Automatic update policies written."

section "AUTOMATIC UPDATE VALIDATION"
apt-config dump >/dev/null 2>&1 && pass "APT configuration parses." || fail "APT configuration parsing failed."
APT_CONFIG="$(apt-config dump 2>/dev/null || true)"
check_cfg(){ printf '%s\n' "$APT_CONFIG" | grep -Fq "$1" && pass "$2" || fail "$2"; }
check_cfg 'APT::Periodic::Update-Package-Lists "1";' "Daily package-list updates enabled."
check_cfg 'APT::Periodic::Unattended-Upgrade "1";' "Daily unattended upgrades enabled."
check_cfg 'Unattended-Upgrade::Remove-Unused-Dependencies "true";' "Unused dependency cleanup enabled."
check_cfg 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";' "Unused kernel cleanup enabled."
check_cfg 'Unattended-Upgrade::Automatic-Reboot "true";' "Automatic reboot enabled."
check_cfg 'Unattended-Upgrade::Automatic-Reboot-WithUsers "false";' "Automatic reboot with logged-in users disabled."
check_cfg "Unattended-Upgrade::Automatic-Reboot-Time \"$REBOOT_TIME\";" "Automatic reboot time is $REBOOT_TIME."

section "APT SYSTEMD TIMERS"
systemctl daemon-reload
for timer in apt-daily.timer apt-daily-upgrade.timer; do
  systemctl enable --now "$timer" >/dev/null 2>&1 && pass "$timer enabled." || fail "Unable to enable $timer."
  systemctl is-enabled --quiet "$timer" && pass "$timer enabled at boot." || fail "$timer not enabled at boot."
  systemctl is-active --quiet "$timer" && pass "$timer active." || fail "$timer inactive."
done
systemctl list-timers apt-daily.timer apt-daily-upgrade.timer --all --no-pager || true

section "REBOOT STATUS"
REBOOT_REQUIRED=false
if [[ -f /var/run/reboot-required ]]; then
  REBOOT_REQUIRED=true
  warn "Initial system updates require a reboot."
  info "Provisioning completed without an immediate reboot."
  info "Automatic reboot policy is configured for $REBOOT_TIME local time."
  if [[ -f /var/run/reboot-required.pkgs ]]; then
    info "Packages requesting the reboot:"
    sed 's/^/  - /' /var/run/reboot-required.pkgs
  fi
else
  pass "No reboot currently reported as required."
fi

section "FINAL DEPLOYMENT REPORT"
echo "Version:             $SCRIPT_VERSION"
echo "Hostname:            $(hostname)"
echo "Architecture:        $ARCHITECTURE"
echo "Updates before:      $PENDING_BEFORE"
echo "Updates remaining:   $PENDING_AFTER"
echo "Existing collector:  $DOMOTZ_ALREADY_INSTALLED"
echo "Installed this run:  $DOMOTZ_INSTALLED_THIS_RUN"
echo "Domotz restarted:    $SHOULD_RESTART"
echo "Automatic updates:   Enabled"
echo "Automatic cleanup:   Enabled"
echo "Reboot required:     $REBOOT_REQUIRED"
echo "Reboot time:         $REBOOT_TIME local time"
echo "Setup log:           $LOG_FILE"
echo "Errors:              $ERRORS"
echo "Warnings:            $WARNINGS"
echo

if [[ "$ERRORS" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}DOMOTZ PI PROVISIONER VALIDATION PASSED${NC}"
  [[ "$WARNINGS" -gt 0 ]] && echo "Validation passed with $WARNINGS warning(s); review [WARN] entries above."
  exit 0
else
  echo -e "${RED}${BOLD}DOMOTZ PI PROVISIONER VALIDATION FAILED${NC}"
  echo "Review [FAIL] entries and $LOG_FILE."
  exit 1
fi
