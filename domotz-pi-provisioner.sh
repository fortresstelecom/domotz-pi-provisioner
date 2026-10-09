#!/usr/bin/env bash

# Domotz Pi Provisioner
# Version: 1.0.0
# License: MIT
#
# Idempotent provisioning and maintenance for Domotz collectors on
# Raspberry Pi OS / Debian-based Raspberry Pi systems.

set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.0"
DOMOTZ_SNAP="domotzpro-agent-publicstore"
LOCAL_POLICY="/etc/apt/apt.conf.d/52-domotz-pi-provisioner"
AUTO_POLICY="/etc/apt/apt.conf.d/20auto-upgrades"
MODULES_FILE="/etc/modules"
REBOOT_TIME="${REBOOT_TIME:-02:00}"
RUN_DRY_RUN="${RUN_DRY_RUN:-true}"
LOG_DIR="/var/log/domotz-pi-provisioner"
LOG_FILE="${LOG_DIR}/setup.log"
DRY_RUN_LOG="${LOG_DIR}/unattended-upgrade-dry-run.log"
BACKUP_DIR="/var/backups/domotz-pi-provisioner"
ERRORS=0
WARNINGS=0

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
command_exists(){ command -v "$1" >/dev/null 2>&1; }

backup_file_once(){
  local source_file="$1" backup_name
  [[ -e "$source_file" ]] || return 0
  backup_name="$(echo "$source_file" | sed 's#^/##; s#/#_#g')"
  if [[ ! -e "${BACKUP_DIR}/${backup_name}.original" ]]; then
    cp -a "$source_file" "${BACKUP_DIR}/${backup_name}.original"
    pass "Created original backup of $source_file."
  else
    info "Original backup already exists for $source_file."
  fi
}

case "$RUN_DRY_RUN" in true|false) ;; *) echo "RUN_DRY_RUN must be true or false."; exit 1;; esac
if [[ $EUID -ne 0 ]]; then echo "Run as root: sudo ./$SCRIPT_NAME"; exit 1; fi
if [[ ! "$REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then echo "Invalid REBOOT_TIME: $REBOOT_TIME"; exit 1; fi

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
chmod 750 "$LOG_DIR" "$BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

section "DOMOTZ PI PROVISIONER"
info "Version: $SCRIPT_VERSION"
info "Hostname: $(hostname)"
info "Started: $(date --iso-8601=seconds 2>/dev/null || date)"
info "Reboot window: $REBOOT_TIME local time"

section "OPERATING SYSTEM VALIDATION"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  info "Operating system: ${PRETTY_NAME:-Unknown}"
  case "${ID:-}" in debian|raspbian) pass "Supported Debian-family OS detected.";; *) warn "OS does not identify as Debian/Raspbian.";; esac
fi
ARCHITECTURE="$(dpkg --print-architecture 2>/dev/null || uname -m)"
info "Architecture: $ARCHITECTURE"
if [[ -r /proc/device-tree/model ]]; then
  DEVICE_MODEL="$(tr -d '\0' < /proc/device-tree/model)"
  info "Hardware model: $DEVICE_MODEL"
  [[ "$DEVICE_MODEL" == *"Raspberry Pi"* ]] && pass "Raspberry Pi hardware detected." || warn "Hardware does not identify as Raspberry Pi."
fi
command_exists apt-get || { fail "apt-get unavailable."; exit 1; }
command_exists systemctl || { fail "systemctl unavailable."; exit 1; }

section "NETWORK AND TIME VALIDATION"
getent hosts deb.debian.org >/dev/null 2>&1 && pass "DNS resolution is working." || fail "Unable to resolve deb.debian.org."
getent hosts archive.raspberrypi.com >/dev/null 2>&1 && pass "Raspberry Pi repository DNS works." || warn "Unable to resolve archive.raspberrypi.com."
if command_exists timedatectl; then
  TIME_SYNC="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  TIMEZONE="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  info "System timezone: ${TIMEZONE:-Unknown}"
  [[ "$TIME_SYNC" == yes ]] && pass "System clock reports synchronized." || warn "System clock does not report NTP synchronization."
fi

section "APT PACKAGE INSTALLATION"
apt-get update && pass "APT metadata refreshed." || { fail "apt-get update failed."; exit 1; }
DEBIAN_FRONTEND=noninteractive apt-get install -y snapd unattended-upgrades ca-certificates && pass "Required packages installed." || { fail "Package installation failed."; exit 1; }

section "SNAP SERVICE"
systemctl daemon-reload
systemctl enable --now snapd.socket >/dev/null 2>&1 && pass "snapd.socket enabled." || fail "Unable to enable snapd.socket."
if [[ ! -e /snap && -d /var/lib/snapd/snap ]]; then ln -s /var/lib/snapd/snap /snap; fi
command_exists snap || { fail "snap command unavailable."; exit 1; }

section "DOMOTZ COLLECTOR"
if snap list "$DOMOTZ_SNAP" >/dev/null 2>&1; then
  DOMOTZ_ALREADY_INSTALLED=true
  pass "Existing Domotz installation detected and will be preserved."
else
  DOMOTZ_ALREADY_INSTALLED=false
  snap install "$DOMOTZ_SNAP" && pass "Domotz installed." || fail "Domotz installation failed."
fi

section "DOMOTZ SNAP INTERFACES"
DOMOTZ_INTERFACES=(firewall-control network-observe raw-usb shutdown system-observe)
for interface in "${DOMOTZ_INTERFACES[@]}"; do
  plug="${DOMOTZ_SNAP}:${interface}"
  if snap connections "$DOMOTZ_SNAP" 2>/dev/null | awk -v target="$plug" '$2==target && $3!="-"{f=1} END{exit !f}'; then
    pass "$plug is connected."
  else
    snap connect "$plug" && pass "$plug connected." || fail "Unable to connect $plug."
  fi
done

section "TUN SUPPORT"
touch "$MODULES_FILE"
grep -Eq '^[[:space:]]*tun([[:space:]]*#.*)?$' "$MODULES_FILE" || printf '\ntun\n' >> "$MODULES_FILE"
modprobe tun && pass "TUN loaded." || fail "Unable to load TUN."
[[ -c /dev/net/tun ]] && pass "/dev/net/tun available." || warn "/dev/net/tun unavailable."

section "DOMOTZ SERVICE VALIDATION"
if snap list "$DOMOTZ_SNAP" >/dev/null 2>&1; then
  snap restart "$DOMOTZ_SNAP" && pass "Domotz restarted." || fail "Domotz restart failed."
  sleep 3
  snap services "$DOMOTZ_SNAP" 2>/dev/null | awk 'NR>1 && $4=="active"{f=1} END{exit !f}' && pass "Domotz service active." || fail "No active Domotz service detected."
fi

section "AUTOMATIC UPDATE POLICY"
backup_file_once "$AUTO_POLICY"
backup_file_once "$LOCAL_POLICY"
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
if apt-config dump >/dev/null 2>&1; then pass "APT configuration parses."; else fail "APT configuration parsing failed."; fi
APT_CONFIG="$(apt-config dump 2>/dev/null || true)"
check_cfg(){ printf '%s\n' "$APT_CONFIG" | grep -Fq "$1" && pass "$2" || fail "$2"; }
check_cfg 'APT::Periodic::Update-Package-Lists "1";' "Daily package-list updates enabled."
check_cfg 'APT::Periodic::Unattended-Upgrade "1";' "Daily unattended upgrades enabled."
check_cfg 'Unattended-Upgrade::Remove-Unused-Dependencies "true";' "Unused dependency cleanup enabled."
check_cfg 'Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";' "Unused kernel cleanup enabled."
check_cfg 'Unattended-Upgrade::Automatic-Reboot "true";' "Automatic reboot enabled."
check_cfg "Unattended-Upgrade::Automatic-Reboot-Time \"$REBOOT_TIME\";" "Automatic reboot time is $REBOOT_TIME."

section "APT SYSTEMD TIMERS"
systemctl daemon-reload
for timer in apt-daily.timer apt-daily-upgrade.timer; do
  systemctl enable --now "$timer" >/dev/null 2>&1 && pass "$timer enabled." || fail "Unable to enable $timer."
  systemctl is-active --quiet "$timer" && pass "$timer active." || fail "$timer inactive."
done
systemctl list-timers apt-daily.timer apt-daily-upgrade.timer --all --no-pager || true

section "PACKAGE MANAGER HEALTH"
DPKG_AUDIT="$(dpkg --audit 2>/dev/null || true)"
[[ -z "$DPKG_AUDIT" ]] && pass "dpkg audit clean." || { fail "dpkg reports issues."; echo "$DPKG_AUDIT"; }
apt-get check >/dev/null 2>&1 && pass "APT dependency check passed." || fail "APT dependency check failed."

section "UNATTENDED-UPGRADE DRY RUN"
if [[ "$RUN_DRY_RUN" == true ]]; then
  if unattended-upgrade --dry-run > "$DRY_RUN_LOG" 2>&1; then
    pass "Unattended-upgrade dry run completed successfully."
  else
    fail "Unattended-upgrade dry run failed."
    tail -n 50 "$DRY_RUN_LOG" || true
  fi
else
  warn "Dry run disabled with RUN_DRY_RUN=false."
fi

section "REBOOT STATUS"
if [[ -f /var/run/reboot-required ]]; then
  warn "Device currently reports reboot required."
  info "Future unattended reboots use $REBOOT_TIME local time."
else
  pass "No reboot currently reported as required."
fi

section "FINAL DEPLOYMENT REPORT"
echo "Version:            $SCRIPT_VERSION"
echo "Hostname:           $(hostname)"
echo "Architecture:       $ARCHITECTURE"
echo "Existing collector: $DOMOTZ_ALREADY_INSTALLED"
echo "Automatic updates:  Enabled"
echo "Automatic cleanup:  Enabled"
echo "Reboot time:        $REBOOT_TIME local time"
echo "Setup log:          $LOG_FILE"
echo "Dry-run log:        $DRY_RUN_LOG"
echo "Errors:             $ERRORS"
echo "Warnings:           $WARNINGS"
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
