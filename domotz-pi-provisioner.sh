#!/usr/bin/env bash
# Domotz Pi Provisioner v1.0.5
# License: MIT

set -u
set -o pipefail

PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
export PATH
umask 027

SCRIPT_VERSION="1.0.5"
DOMOTZ_SNAP="domotzpro-agent-publicstore"
REBOOT_TIME="${REBOOT_TIME:-02:00}"
RESTART_DOMOTZ="${RESTART_DOMOTZ:-auto}"
MIN_FREE_ROOT_MB="${MIN_FREE_ROOT_MB:-2048}"
ALLOW_PACKAGE_REMOVALS="${ALLOW_PACKAGE_REMOVALS:-false}"

LOG_DIR="/var/log/domotz-pi-provisioner"
LOG_FILE="$LOG_DIR/setup.log"
UPGRADE_PLAN="$LOG_DIR/full-upgrade-plan.log"
BACKUP_DIR="/var/backups/domotz-pi-provisioner"
STATE_DIR="/var/lib/domotz-pi-provisioner"
LOCK_FILE="/run/lock/domotz-pi-provisioner.lock"
AUTO_POLICY="/etc/apt/apt.conf.d/20auto-upgrades"
LOCAL_POLICY="/etc/apt/apt.conf.d/52-domotz-pi-provisioner"
PERSISTENT_LAUNCHER="/usr/local/sbin/domotz-pi-provisioner"
COMPLETION_MARKER="$STATE_DIR/rerun-required"
MOTD_NOTICE="/etc/motd.d/99-domotz-pi-provisioner"
MODULES_FILE="/etc/modules"
LD_PRELOAD_FILE="/etc/ld.so.preload"
SSH_CONFIG_FILE="/etc/ssh/ssh_config"

ERRORS=0
WARNINGS=0
EXISTING_COLLECTOR=false
INSTALLED_THIS_RUN=false
DOMOTZ_RESTARTED=false
REBOOT_REQUIRED=false
PENDING_BEFORE=0
PENDING_AFTER=0
ROOT_FREE_MB=0

if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

pass() { echo -e "${GREEN}[PASS]${RESET} $*"; }
fail() { echo -e "${RED}[FAIL]${RESET} $*"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "${YELLOW}[WARN]${RESET} $*"; WARNINGS=$((WARNINGS + 1)); }
info() { echo -e "${BLUE}[INFO]${RESET} $*"; }
section() {
  echo
  echo -e "${BOLD}==============================================================================${RESET}"
  echo -e "${BOLD}$*${RESET}"
  echo -e "${BOLD}==============================================================================${RESET}"
}
has() { command -v "$1" >/dev/null 2>&1; }

reject_symlink() {
  local target="$1"
  if [[ -L "$target" ]]; then
    fail "Refusing to write through symbolic link: $target"
    exit 1
  fi
}

secure_directory() {
  local directory="$1"
  local mode="$2"
  if [[ -L "$directory" ]]; then
    fail "Refusing symbolic-link directory: $directory"
    exit 1
  fi
  install -d -o root -g root -m "$mode" "$directory"
}

backup_once() {
  local source_file="$1"
  local backup_name
  [[ -e "$source_file" ]] || return 0
  backup_name="$(printf '%s' "$source_file" | sed 's#^/##;s#/#_#g')"
  reject_symlink "$BACKUP_DIR/$backup_name.original"
  if [[ ! -e "$BACKUP_DIR/$backup_name.original" ]]; then
    cp -a -- "$source_file" "$BACKUP_DIR/$backup_name.original"
    chown root:root "$BACKUP_DIR/$backup_name.original"
    pass "Created original backup of $source_file."
  else
    info "Original backup already exists for $source_file."
  fi
}

count_pending_updates() {
  apt list --upgradable 2>/dev/null | awk 'NR > 1 {count++} END {print count+0}'
}

[[ $EUID -eq 0 ]] || { echo "Run with sudo or as root."; exit 1; }
case "$RESTART_DOMOTZ" in auto|true|false) ;; *) echo "RESTART_DOMOTZ must be auto, true, or false"; exit 1 ;; esac
case "$ALLOW_PACKAGE_REMOVALS" in true|false) ;; *) echo "ALLOW_PACKAGE_REMOVALS must be true or false"; exit 1 ;; esac
[[ "$REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "REBOOT_TIME must use HH:MM format"; exit 1; }
[[ "$MIN_FREE_ROOT_MB" =~ ^[0-9]+$ ]] || { echo "MIN_FREE_ROOT_MB must be numeric"; exit 1; }

has flock || { echo "flock is required but unavailable."; exit 1; }
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another Domotz Pi Provisioner instance is already running."
  exit 1
fi

secure_directory "$LOG_DIR" 0750
secure_directory "$BACKUP_DIR" 0750
secure_directory "$STATE_DIR" 0750
secure_directory /etc/motd.d 0755
reject_symlink "$LOG_FILE"
touch "$LOG_FILE"
chown root:root "$LOG_FILE"
chmod 0640 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

section "PERSISTENT PROVISIONER COMMAND"
CURRENT_SCRIPT="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"
LAUNCHER_REAL="$(readlink -f "$PERSISTENT_LAUNCHER" 2>/dev/null || printf '%s' "$PERSISTENT_LAUNCHER")"
reject_symlink "$PERSISTENT_LAUNCHER"
if [[ ! -f "$CURRENT_SCRIPT" ]]; then
  fail "Unable to locate the running provisioner script."
  exit 1
elif [[ "$CURRENT_SCRIPT" == "$LAUNCHER_REAL" ]]; then
  pass "Running from persistent provisioner command: $PERSISTENT_LAUNCHER"
else
  install -o root -g root -m 0755 "$CURRENT_SCRIPT" "$PERSISTENT_LAUNCHER"
  pass "Installed persistent provisioner command: $PERSISTENT_LAUNCHER"
fi

section "DOMOTZ PI PROVISIONER"
info "Version: $SCRIPT_VERSION"
info "Hostname: $(hostname)"
info "Started: $(date --iso-8601=seconds 2>/dev/null || date)"
info "Reboot window: $REBOOT_TIME local time"
info "Domotz restart policy: $RESTART_DOMOTZ"
info "Package removal policy: $ALLOW_PACKAGE_REMOVALS"
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
has snap || info "snap is not installed yet and will be installed during provisioning."

section "NETWORK AND TIME VALIDATION"
getent hosts deb.debian.org >/dev/null 2>&1 && pass "DNS resolution is working." || { fail "Unable to resolve deb.debian.org."; exit 1; }
getent hosts archive.raspberrypi.com >/dev/null 2>&1 && pass "Raspberry Pi repository DNS works." || warn "Unable to resolve archive.raspberrypi.com."
if has timedatectl; then
  TIMEZONE="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  TIME_SYNC="$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)"
  info "System timezone: ${TIMEZONE:-Unknown}"
  [[ "$TIME_SYNC" == yes ]] && pass "System clock reports synchronized." || warn "System clock does not report NTP synchronization."
fi

section "PRE-UPGRADE PACKAGE HEALTH"
DPKG_AUDIT="$(dpkg --audit 2>/dev/null || true)"
if [[ -n "$DPKG_AUDIT" ]]; then
  fail "dpkg reports incomplete package operations:"
  echo "$DPKG_AUDIT"
  exit 1
fi
pass "dpkg audit clean."
apt-get check >/dev/null 2>&1 && pass "APT dependency check passed." || { fail "APT dependency check failed."; exit 1; }

section "APT REPOSITORY INVENTORY"
info "Enabled APT repositories will be used for the mandatory initial update."
if [[ -f /etc/apt/sources.list ]]; then
  grep -E '^[[:space:]]*deb[[:space:]]' /etc/apt/sources.list || true
fi
find /etc/apt/sources.list.d -maxdepth 1 -type f -name '*.list' -exec grep -H -E '^[[:space:]]*deb[[:space:]]' {} + 2>/dev/null || true
for source_file in /etc/apt/sources.list.d/*.sources; do
  [[ -f "$source_file" ]] || continue
  echo "[$source_file]"
  sed -n '/^Types:/p;/^URIs:/p;/^Suites:/p;/^Components:/p;/^Signed-By:/p' "$source_file"
done

section "APT METADATA REFRESH"
apt-get update && pass "APT metadata refreshed." || { fail "apt-get update failed."; exit 1; }
PENDING_BEFORE="$(count_pending_updates)"
info "Pending package updates before initial upgrade: $PENDING_BEFORE"

section "DISK SPACE PREFLIGHT"
ROOT_AVAIL_KB="$(df -Pk / | awk 'NR == 2 {print $4}')"
ROOT_FREE_MB=$((ROOT_AVAIL_KB / 1024))
ROOT_FREE_GB="$(awk -v kb="$ROOT_AVAIL_KB" 'BEGIN {printf "%.2f", kb/1024/1024}')"
info "Available root filesystem space: $ROOT_FREE_GB GiB ($ROOT_FREE_MB MiB)."
info "Minimum required free space: $MIN_FREE_ROOT_MB MiB."
if [[ "$ROOT_FREE_MB" -lt "$MIN_FREE_ROOT_MB" ]]; then
  fail "Insufficient free disk space for the initial system update."
  exit 1
fi
pass "Disk-space preflight passed."

section "FULL-UPGRADE SECURITY PREVIEW"
reject_symlink "$UPGRADE_PLAN"
if apt-get --simulate full-upgrade > "$UPGRADE_PLAN" 2>&1; then
  chown root:root "$UPGRADE_PLAN"
  chmod 0640 "$UPGRADE_PLAN"
  pass "Full-upgrade simulation completed."
else
  fail "Unable to simulate the full system upgrade."
  tail -n 50 "$UPGRADE_PLAN" || true
  exit 1
fi

REMOVAL_COUNT="$(grep -c '^Remv ' "$UPGRADE_PLAN" || true)"
info "Proposed package removals: $REMOVAL_COUNT"
if [[ "$REMOVAL_COUNT" -gt 0 ]]; then
  grep '^Remv ' "$UPGRADE_PLAN"
  if [[ "$ALLOW_PACKAGE_REMOVALS" != true ]]; then
    fail "Full-upgrade proposes removing installed packages."
    info "Review $UPGRADE_PLAN and rerun with ALLOW_PACKAGE_REMOVALS=true only if the removals are approved."
    exit 1
  fi
  warn "Proceeding with approved package removals."
else
  pass "Full-upgrade simulation proposes no package removals."
fi

section "INITIAL SYSTEM UPDATE"
if [[ "$PENDING_BEFORE" -gt 0 ]]; then
  info "Installing all currently available updates before provisioning."
  if DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confold" full-upgrade; then
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
if [[ -n "$DPKG_AUDIT" ]]; then
  fail "dpkg reports incomplete package operations after the update:"
  echo "$DPKG_AUDIT"
else
  pass "dpkg audit clean after the update."
fi
apt-get check >/dev/null 2>&1 && pass "APT dependency check passed after the update." || fail "APT dependency check failed after the update."
PENDING_AFTER="$(count_pending_updates)"
[[ "$PENDING_AFTER" -eq 0 ]] && pass "No package updates remain pending." || warn "$PENDING_AFTER package update(s) remain pending."

section "REQUIRED PACKAGE INSTALLATION"
if DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confold" snapd unattended-upgrades ca-certificates; then
  pass "Required packages are installed."
else
  fail "Required package installation failed."
  exit 1
fi
systemctl daemon-reload
systemctl enable --now snapd.socket >/dev/null 2>&1 && pass "snapd.socket enabled." || { fail "Unable to enable snapd.socket."; exit 1; }
if [[ ! -e /snap && -d /var/lib/snapd/snap ]]; then
  ln -s /var/lib/snapd/snap /snap
  pass "Created /snap compatibility link."
fi
has snap || { fail "snap command unavailable after installation."; exit 1; }

section "DOMOTZ COLLECTOR"
if snap list "$DOMOTZ_SNAP" >/dev/null 2>&1; then
  EXISTING_COLLECTOR=true
  pass "Existing Domotz installation detected and preserved."
else
  if snap install "$DOMOTZ_SNAP"; then
    INSTALLED_THIS_RUN=true
    pass "Domotz installed."
  else
    fail "Domotz installation failed."
    exit 1
  fi
fi

section "DOMOTZ SNAP INTERFACES"
for interface in firewall-control network-observe raw-usb shutdown system-observe; do
  plug="$DOMOTZ_SNAP:$interface"
  if snap connections "$DOMOTZ_SNAP" 2>/dev/null | awk -v target="$plug" '$2==target && $3!="-" {found=1} END {exit !found}'; then
    pass "$plug is connected."
  else
    snap connect "$plug" && pass "$plug connected." || fail "Unable to connect $plug."
  fi
done

section "TUN SUPPORT"
reject_symlink "$MODULES_FILE"
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
  reject_symlink "$LD_PRELOAD_FILE"
  backup_once "$LD_PRELOAD_FILE"
  sed -Ei '/^[[:space:]]*[^#].*libarmmem.*\.so[[:space:]]*$/ s/^([[:space:]]*)/\1# Domotz Pi Provisioner: /' "$LD_PRELOAD_FILE"
fi
if [[ -f "$SSH_CONFIG_FILE" ]]; then
  reject_symlink "$SSH_CONFIG_FILE"
  backup_once "$SSH_CONFIG_FILE"
  sed -Ei '/^[[:space:]]*Include[[:space:]]+\/etc\/ssh\/ssh_config\.d\/\*\.conf[[:space:]]*$/ s/^([[:space:]]*)/\1# Domotz Pi Provisioner: /' "$SSH_CONFIG_FILE"
  ssh -G localhost >/dev/null 2>&1 && pass "SSH client configuration parses successfully." || warn "SSH client configuration validation returned an error."
fi

section "DOMOTZ RESTART POLICY"
SHOULD_RESTART=false
case "$RESTART_DOMOTZ" in
  true) SHOULD_RESTART=true ;;
  false) SHOULD_RESTART=false ;;
  auto) [[ "$INSTALLED_THIS_RUN" == true ]] && SHOULD_RESTART=true ;;
esac
if [[ "$SHOULD_RESTART" == true ]]; then
  [[ "$EXISTING_COLLECTOR" == true ]] && warn "Restarting an existing Collector may interrupt Domotz Remote Access."
  if snap restart "$DOMOTZ_SNAP"; then
    DOMOTZ_RESTARTED=true
    pass "Domotz restart completed."
  else
    fail "Domotz restart failed."
  fi
  sleep 3
else
  pass "Existing Domotz Collector restart skipped to preserve remote access."
fi

section "DOMOTZ SERVICE VALIDATION"
DOMOTZ_SERVICES="$(snap services "$DOMOTZ_SNAP" 2>/dev/null || true)"
if printf '%s\n' "$DOMOTZ_SERVICES" | awk 'NR>1 && $3=="active" {found=1} END {exit !found}'; then
  pass "At least one Domotz service is active."
else
  fail "No active Domotz service detected."
  printf '%s\n' "$DOMOTZ_SERVICES"
fi

section "AUTOMATIC UPDATE POLICY"
reject_symlink "$AUTO_POLICY"
reject_symlink "$LOCAL_POLICY"
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
chown root:root "$AUTO_POLICY" "$LOCAL_POLICY"
chmod 0644 "$AUTO_POLICY" "$LOCAL_POLICY"
pass "Automatic update policies written."
apt-config dump >/dev/null 2>&1 && pass "APT configuration parses." || fail "APT configuration parsing failed."
for timer in apt-daily.timer apt-daily-upgrade.timer; do
  systemctl enable --now "$timer" >/dev/null 2>&1 && pass "$timer enabled." || fail "Unable to enable $timer."
  systemctl is-enabled --quiet "$timer" && pass "$timer enabled at boot." || fail "$timer not enabled at boot."
  systemctl is-active --quiet "$timer" && pass "$timer active." || fail "$timer inactive."
done

section "REBOOT STATUS"
reject_symlink "$MOTD_NOTICE"
reject_symlink "$COMPLETION_MARKER"
if [[ -f /var/run/reboot-required ]]; then
  REBOOT_REQUIRED=true
  warn "System updates require a reboot."
  touch "$COMPLETION_MARKER"
  chown root:root "$COMPLETION_MARKER"
  chmod 0640 "$COMPLETION_MARKER"
  cat > "$MOTD_NOTICE" <<'EOF'

*** DOMOTZ PI PROVISIONING INCOMPLETE ***
A reboot was required during provisioning.
Rerun the provisioner to complete final validation.

Copy/paste:
sudo domotz-pi-provisioner

EOF
  chown root:root "$MOTD_NOTICE"
  chmod 0644 "$MOTD_NOTICE"
  pass "Installed post-reboot login reminder."
else
  pass "No reboot required."
  if [[ -f "$COMPLETION_MARKER" ]]; then
    rm -f -- "$COMPLETION_MARKER" "$MOTD_NOTICE"
    pass "Post-reboot validation complete; login reminder removed."
  fi
fi

section "FINAL DEPLOYMENT REPORT"
printf 'Version:             %s\nHostname:            %s\nArchitecture:        %s\nUpdates before:      %s\nRoot free preflight: %s MiB\nUpdates remaining:   %s\nExisting collector:  %s\nInstalled this run:  %s\nDomotz restarted:    %s\nReboot required:     %s\nSetup log:           %s\nUpgrade plan:        %s\nErrors:              %s\nWarnings:            %s\n' \
  "$SCRIPT_VERSION" "$(hostname)" "$ARCHITECTURE" "$PENDING_BEFORE" "$ROOT_FREE_MB" "$PENDING_AFTER" \
  "$EXISTING_COLLECTOR" "$INSTALLED_THIS_RUN" "$DOMOTZ_RESTARTED" "$REBOOT_REQUIRED" \
  "$LOG_FILE" "$UPGRADE_PLAN" "$ERRORS" "$WARNINGS"

if [[ "$ERRORS" -eq 0 ]]; then
  echo -e "${GREEN}${BOLD}DOMOTZ PI PROVISIONER VALIDATION PASSED${RESET}"
  [[ "$WARNINGS" -gt 0 ]] && echo "Validation passed with $WARNINGS warning(s); review [WARN] entries above."
  if [[ "$REBOOT_REQUIRED" == true ]]; then
    if [[ -t 0 ]]; then
      while true; do
        read -r -p "Reboot required. Reboot now? [y/N]: " response
        case "$response" in
          [Yy]|[Yy][Ee][Ss]) info "Rebooting now."; sync; systemctl reboot; exit 0 ;;
          [Nn]|[Nn][Oo]|"") info "Reboot deferred. Run sudo domotz-pi-provisioner after reboot."; break ;;
          *) echo "Please answer Y or N." ;;
        esac
      done
    else
      warn "Reboot required; noninteractive execution did not reboot automatically."
    fi
  fi
  exit 0
else
  echo -e "${RED}${BOLD}DOMOTZ PI PROVISIONER VALIDATION FAILED${RESET}"
  echo "Review [FAIL] entries and $LOG_FILE."
  exit 1
fi
