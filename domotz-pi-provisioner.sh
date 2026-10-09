#!/usr/bin/env bash

# Domotz Pi Provisioner
# Version: 1.0.1
# License: MIT
#
# Idempotent provisioning and maintenance for Domotz collectors on
# Raspberry Pi OS / Debian-based Raspberry Pi systems.
#
# v1.0.1 changes:
#   - Existing Domotz collectors are no longer restarted by default.
#   - Adds the Raspberry Pi compatibility adjustments documented by Domotz.
#   - Adds RESTART_DOMOTZ=auto|true|false control.
#   - Separates service validation from service restart behavior.

set -u
set -o pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="1.0.1"
DOMOTZ_SNAP="domotzpro-agent-publicstore"
LOCAL_POLICY="/etc/apt/apt.conf.d/52-domotz-pi-provisioner"
AUTO_POLICY="/etc/apt/apt.conf.d/20auto-upgrades"
MODULES_FILE="/etc/modules"
LD_PRELOAD_FILE="/etc/ld.so.preload"
SSH_CONFIG_FILE="/etc/ssh/ssh_config"
REBOOT_TIME="${REBOOT_TIME:-02:00}"
RUN_DRY_RUN="${RUN_DRY_RUN:-true}"
RESTART_DOMOTZ="${RESTART_DOMOTZ:-auto}"
LOG_DIR="/var/log/domotz-pi-provisioner"
LOG_FILE="${LOG_DIR}/setup.log"
DRY_RUN_LOG="${LOG_DIR}/unattended-upgrade-dry-run.log"
BACKUP_DIR="/var/backups/domotz-pi-provisioner"
ERRORS=0
WARNINGS=0
DOMOTZ_INSTALLED_THIS_RUN=false
COMPATIBILITY_CHANGED=false

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
case "$RESTART_DOMOTZ" in auto|true|false) ;; *) echo "RESTART_DOMOTZ must be auto, true, or false."; exit 1;; esac
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
info "Domotz restart policy: $RESTART_DOMOTZ"

section "OPERATING SYSTEM VALIDATION"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
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
if [[ ! -e /snap && -d /var/lib/snapd/snap ]]; then ln -s /var/lib/snapd/snap /snap; pass "Created /snap compatibility link."; fi
command_exists snap || { fail "snap command unavailable."; exit 1; }

section "DOMOTZ COLLECTOR"
if snap list "$DOMOTZ_SNAP" >/dev/null 2>&1; then
  DOMOTZ_ALREADY_INSTALLED=true
  pass "Existing Domotz installation detected and will be preserved."
else
  DOMOTZ_ALREADY_INSTALLED=false
  if snap install "$DOMOTZ_SNAP"; then
    DOMOTZ_INSTALLED_THIS_RUN=true
    pass "Domotz installed."
  else
    fail "Domotz installation failed."
  fi
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
  backup_file_once "$LD_PRELOAD_FILE"
  if grep -Eq '^[[:space:]]*[^#].*libarmmem.*\.so([[:space:]]*)$' "$LD_PRELOAD_FILE"; then
    sed -Ei '/^[[:space:]]*[^#].*libarmmem.*\.so([[:space:]]*)$/ s/^([[:space:]]*)/\1# Domotz Pi Provisioner: /' "$LD_PRELOAD_FILE"
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
  backup_file_once "$SSH_CONFIG_FILE"
  if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/ssh_config\.d/\*\.conf([[:space:]]*)$' "$SSH_CONFIG_FILE"; then
    sed -Ei '/^[[:space:]]*Include[[:space:]]+\/etc\/ssh\/ssh_config\.d\/\*\.conf([[:space:]]*)$/ s/^([[:space:]]*)/\1# Domotz Pi Provisioner: /' "$SSH_CONFIG_FILE"
    COMPATIBILITY_CHANGED=true
    pass "Disabled the global SSH client Include directive used by the Domotz compatibility procedure."
  elif grep -Eq '^[[:space:]]*#.*Include[[:space:]]+/etc/ssh/ssh_config\.d/\*\.conf' "$SSH_CONFIG_FILE"; then
    pass "Global SSH client Include directive is already disabled."
  else
    info "Specified global SSH client Include directive not found; no change required."
  fi
else
  warn "$SSH_CONFIG_FILE does not exist."
fi

if command_exists ssh; then
  ssh -G localhost >/dev/null 2>&1 && pass "SSH client configuration parses successfully." || warn "SSH client configuration validation returned an error."
fi

section "DOMOTZ RESTART POLICY"
SHOULD_RESTART=false
case "$RESTART_DOMOTZ" in
  true) SHOULD_RESTART=true ;;
  false) SHOULD_RESTART=false ;;
  auto)
    [[ "$DOMOTZ_INSTALLED_THIS_RUN" == true ]] && SHOULD_RESTART=true
    ;;
esac

if [[ "$SHOULD_RESTART" == true ]]; then
  if [[ "$DOMOTZ_ALREADY_INSTALLED" == true ]]; then
    warn "Restarting an existing Domotz Collector because RESTART_DOMOTZ=true."
    warn "A session using Domotz Remote Access may be interrupted."
  else
    info "Restarting the newly installed Domotz Collector."
  fi
  snap restart "$DOMOTZ_SNAP" && pass "Domotz restart completed." || fail "Domotz restart failed."
  sleep 3
else
  if [[ "$DOMOTZ_ALREADY_INSTALLED" == true ]]; then
    pass "Existing Domotz Collector restart skipped to preserve remote access."
    [[ "$COMPATIBILITY_CHANGED" == true ]] && warn "Compatibility settings changed; apply a controlled Domotz restart later if required."
  else
    warn "Domotz restart skipped by RESTART_DOMOTZ=false."
  fi
fi

section "DOMOTZ SERVICE VALIDATION"
if snap list "$DOMOTZ_SNAP" >/dev/null 2>&1; then
  if snap services "$DOMOTZ_SNAP" 2>/dev/null | awk 'NR>1 && $4=="active"{f=1} END{exit !f}'; then
    pass "At least one Domotz service is active."
  else
    warn "No active Domotz service detected; attempting a non-disruptive start."
    snap start "$DOMOTZ_SNAP" && pass "Domotz start command completed." || fail "Unable to start Domotz."
    sleep 3
    snap services "$DOMOTZ_SNAP" 2>/dev/null | awk 'NR>1 && $4=="active"{f=1} END{exit !f}' && pass "Domotz service is active." || fail "No active Domotz service detected after start attempt."
  fi
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
echo "Version:             $SCRIPT_VERSION"
echo "Hostname:            $(hostname)"
echo "Architecture:        $ARCHITECTURE"
echo "Existing collector:  $DOMOTZ_ALREADY_INSTALLED"
echo "Installed this run:  $DOMOTZ_INSTALLED_THIS_RUN"
echo "Domotz restarted:    $SHOULD_RESTART"
echo "Automatic updates:   Enabled"
echo "Automatic cleanup:   Enabled"
echo "Reboot time:         $REBOOT_TIME local time"
echo "Setup log:           $LOG_FILE"
echo "Dry-run log:         $DRY_RUN_LOG"
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
