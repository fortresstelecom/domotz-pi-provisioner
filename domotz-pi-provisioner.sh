#!/usr/bin/env bash
# Domotz Pi Provisioner v1.0.2
# License: MIT
set -u
set -o pipefail

SCRIPT_VERSION="1.0.2"
DOMOTZ_SNAP="domotzpro-agent-publicstore"
AUTO_POLICY="/etc/apt/apt.conf.d/20auto-upgrades"
LOCAL_POLICY="/etc/apt/apt.conf.d/52-domotz-pi-provisioner"
MODULES_FILE="/etc/modules"
LD_PRELOAD_FILE="/etc/ld.so.preload"
SSH_CONFIG_FILE="/etc/ssh/ssh_config"
REBOOT_TIME="${REBOOT_TIME:-02:00}"
RUN_DRY_RUN="${RUN_DRY_RUN:-true}"
RESTART_DOMOTZ="${RESTART_DOMOTZ:-auto}"
LOG_DIR="/var/log/domotz-pi-provisioner"
LOG_FILE="$LOG_DIR/setup.log"
DRY_RUN_LOG="$LOG_DIR/unattended-upgrade-dry-run.log"
BACKUP_DIR="/var/backups/domotz-pi-provisioner"
ERRORS=0
WARNINGS=0
DOMOTZ_ALREADY_INSTALLED=false
DOMOTZ_INSTALLED_THIS_RUN=false
COMPATIBILITY_CHANGED=false
SHOULD_RESTART=false

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
  local f="$1" n
  [[ -e "$f" ]] || return 0
  n="$(echo "$f" | sed 's#^/##;s#/#_#g')"
  if [[ ! -e "$BACKUP_DIR/$n.original" ]]; then
    cp -a "$f" "$BACKUP_DIR/$n.original"
    pass "Created original backup of $f."
  else
    info "Original backup already exists for $f."
  fi
}

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo ./$0"; exit 1; }
case "$RUN_DRY_RUN" in true|false) ;; *) echo "RUN_DRY_RUN must be true or false"; exit 1;; esac
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

section "OPERATING SYSTEM VALIDATION"
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  info "Operating system: ${PRETTY_NAME:-Unknown}"
  case "${ID:-}" in debian|raspbian) pass "Supported Debian-family OS detected.";; *) warn "OS does not identify as Debian/Raspbian.";; esac
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
  TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  SYNC="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  info "System timezone: ${TZ:-Unknown}"
  [[ "$SYNC" == yes ]] && pass "System clock reports synchronized." || warn "System clock does not report NTP synchronization."
fi

section "APT PACKAGE INSTALLATION"
apt-get update && pass "APT metadata refreshed." || { fail "apt-get update failed."; exit 1; }
DEBIAN_FRONTEND=noninteractive apt-get install -y snapd unattended-upgrades ca-certificates && pass "Required packages installed." || { fail "Package installation failed."; exit 1; }

section "SNAP SERVICE"
systemctl daemon-reload
systemctl enable --now snapd.socket >/dev/null 2>&1 && pass "snapd.socket enabled." || fail "Unable to enable snapd.socket."
[[ -e /snap || ! -d /var/lib/snapd/snap ]] || { ln -s /var/lib/snapd/snap /snap; pass "Created /snap compatibility link."; }
has snap || { fail "snap command unavailable."; exit 1; }

section "DOMOTZ COLLECTOR"
if snap list "$DOMOTZ_SNAP" >/dev/null 2>&1; then
  DOMOTZ_ALREADY_INSTALLED=true
  pass "Existing Domotz installation detected and will be preserved."
else
  if snap install "$DOMOTZ_SNAP"; then DOMOTZ_INSTALLED_THIS_RUN=true; pass "Domotz installed."; else fail "Domotz installation failed."; fi
fi

section "DOMOTZ SNAP INTERFACES"
for interface in firewall-control network-observe raw-usb shutdown system-observe; do
  plug="$DOMOTZ_SNAP:$interface"
  if snap connections "$DOMOTZ_SNAP" 2>/dev/null | awk -v target="$plug" '$2==target && $3!="-"{f=1} END{exit !f}'; then
    pass "$plug is connected."
  else
    snap connect "$plug" && pass "$plug connected." || fail "Unable to connect $plug."
  fi
done

section "TUN SUPPORT"
touch "$MODULES_FILE"
if grep -Eq '^[[:space:]]*tun([[:space:]]*#.*)?$' "$MODULES_FILE"; then pass "TUN is configured to load at boot."; else printf '\ntun\n' >> "$MODULES_FILE"; pass "Added TUN to $MODULES_FILE."; fi
modprobe tun && pass "TUN loaded." || fail "Unable to load TUN."
[[ -c /dev/net/tun ]] && pass "/dev/net/tun available." || warn "/dev/net/tun unavailable."

section "DOMOTZ COMPATIBILITY SETTINGS"
if [[ -f "$LD_PRELOAD_FILE" ]]; then
  backup_once "$LD_PRELOAD_FILE"
  if grep -Eq '^[[:space:]]*[^#].*libarmmem.*\.so[[:space:]]*$' "$LD_PRELOAD_FILE"; then
    sed -Ei '/^[[:space:]]*[^#].*libarmmem.*\.so[[:space:]]*$/ s/^([[:space:]]*)/\1# Domotz Pi Provisioner: /' "$LD_PRELOAD_FILE"
    COMPATIBILITY_CHANGED=true; pass "Disabled the active libarmmem preload entry."
  elif grep -Eq '^[[:space:]]*#.*libarmmem.*\.so' "$LD_PRELOAD_FILE"; then pass "libarmmem preload entry is already disabled."; else info "No libarmmem preload entry found; no change required."; fi
else
  info "$LD_PRELOAD_FILE does not exist; no change required."
fi
if [[ -f "$SSH_CONFIG_FILE" ]]; then
  backup_once "$SSH_CONFIG_FILE"
  if grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/ssh_config\.d/\*\.conf[[:space:]]*$' "$SSH_CONFIG_FILE"; then
    sed -Ei '/^[[:space:]]*Include[[:space:]]+\/etc\/ssh\/ssh_config\.d\/\*\.conf[[:space:]]*$/ s/^([[:space:]]*)/\1# Domotz Pi Provisioner: /' "$SSH_CONFIG_FILE"
    COMPATIBILITY_CHANGED=true; pass "Disabled the global SSH client Include directive."
  elif grep -Eq '^[[:space:]]*#.*Include[[:space:]]+/etc/ssh/ssh_config\.d/\*\.conf' "$SSH_CONFIG_FILE"; then pass "Global SSH client Include directive is already disabled."; else info "Specified SSH Include directive not found; no change required."; fi
else
  warn "$SSH_CONFIG_FILE does not exist."
fi
has ssh && { ssh -G localhost >/dev/null 2>&1 && pass "SSH client configuration parses successfully." || warn "SSH client configuration validation returned an error."; }

section "DOMOTZ RESTART POLICY"
case "$RESTART_DOMOTZ" in true) SHOULD_RESTART=true;; false) SHOULD_RESTART=false;; auto) [[ "$DOMOTZ_INSTALLED_THIS_RUN" == true ]] && SHOULD_RESTART=true;; esac
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
  SERVICES="$(snap services "$DOMOTZ_SNAP" 2>/dev/null || true)"
  if printf '%s\n' "$SERVICES" | awk 'NR>1 && $3=="active"{f=1} END{exit !f}'; then
    pass "At least one Domotz service is active."
  else
    fail "No active Domotz service detected."
    printf '%s\n' "$SERVICES"
    [[ "$DOMOTZ_ALREADY_INSTALLED" == true ]] && { warn "Existing Collector service state was not changed automatically."; warn "Review service output and logs before starting or restarting Domotz."; }
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

section "PACKAGE MANAGER HEALTH"
AUDIT="$(dpkg --audit 2>/dev/null || true)"
[[ -z "$AUDIT" ]] && pass "dpkg audit clean." || { fail "dpkg reports issues."; echo "$AUDIT"; }
apt-get check >/dev/null 2>&1 && pass "APT dependency check passed." || fail "APT dependency check failed."

section "UNATTENDED-UPGRADE DRY RUN"
if [[ "$RUN_DRY_RUN" == true ]]; then
  info "Running unattended-upgrade dry run..."
  info "Detailed output: $DRY_RUN_LOG"
  unattended-upgrade --dry-run > "$DRY_RUN_LOG" 2>&1 &
  DRY_RUN_PID=$!
  DRY_RUN_START=$SECONDS
  SPINNER='|/-\'
  SPINNER_POS=0
  while kill -0 "$DRY_RUN_PID" 2>/dev/null; do
    ELAPSED=$((SECONDS - DRY_RUN_START))
    SPINNER_CHAR="${SPINNER:SPINNER_POS%${#SPINNER}:1}"
    printf "\r[....] Dry run in progress %s %02d:%02d" "$SPINNER_CHAR" "$((ELAPSED / 60))" "$((ELAPSED % 60))"
    SPINNER_POS=$((SPINNER_POS + 1))
    sleep 1
  done
  wait "$DRY_RUN_PID"
  DRY_RUN_STATUS=$?
  ELAPSED=$((SECONDS - DRY_RUN_START))
  printf "\r%*s\r" 70 ""
  ELAPSED_TEXT="$(printf '%02d:%02d' "$((ELAPSED / 60))" "$((ELAPSED % 60))")"
  if [[ "$DRY_RUN_STATUS" -eq 0 ]]; then
    pass "Unattended-upgrade dry run completed successfully in $ELAPSED_TEXT."
  else
    fail "Unattended-upgrade dry run failed after $ELAPSED_TEXT."
    tail -n 50 "$DRY_RUN_LOG" || true
  fi
else
  warn "Dry run disabled with RUN_DRY_RUN=false."
fi

section "REBOOT STATUS"
if [[ -f /var/run/reboot-required ]]; then warn "Device currently reports reboot required."; info "Future unattended reboots use $REBOOT_TIME local time."; else pass "No reboot currently reported as required."; fi

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
