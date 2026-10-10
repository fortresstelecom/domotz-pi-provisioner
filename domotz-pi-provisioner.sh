#!/usr/bin/env bash
# Domotz Pi Provisioner v1.0.6
# License: MIT
set -u
set -o pipefail
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'; export PATH
umask 027

SCRIPT_VERSION="1.0.6"
DOMOTZ_SNAP="domotzpro-agent-publicstore"
REBOOT_TIME="${REBOOT_TIME:-02:00}"
RESTART_DOMOTZ="${RESTART_DOMOTZ:-auto}"
MIN_FREE_ROOT_MB="${MIN_FREE_ROOT_MB:-2048}"
RUN_MODE="${RUN_MODE:-}"
POST_REBOOT_RUN=false
MODE_EXPLICIT=false
LOG_DIR="/var/log/domotz-pi-provisioner"
LOG_FILE="$LOG_DIR/setup.log"
UPGRADE_PLAN="$LOG_DIR/full-upgrade-plan.log"
BACKUP_DIR="/var/backups/domotz-pi-provisioner"
STATE_DIR="/var/lib/domotz-pi-provisioner"
LOCK_FILE="/run/lock/domotz-pi-provisioner.lock"
AUTO_POLICY="/etc/apt/apt.conf.d/20auto-upgrades"
LOCAL_POLICY="/etc/apt/apt.conf.d/52-domotz-pi-provisioner"
LAUNCHER="/usr/local/sbin/domotz-pi-provisioner"
MARKER="$STATE_DIR/rerun-required"
MOTD="/etc/motd.d/99-domotz-pi-provisioner"
POST_UNIT="/etc/systemd/system/domotz-pi-provisioner-post-reboot.service"
POST_UNIT_NAME="domotz-pi-provisioner-post-reboot.service"
ERRORS=0; WARNINGS=0
EXISTING=false; INSTALLED=false; RESTARTED=false; REBOOT_REQUIRED=false
PENDING_BEFORE=0; PENDING_AFTER=0; FREE_MB=0
WARNING_MESSAGES=(); ERROR_MESSAGES=(); IMPORTANT_ACTIONS=()

if [[ -t 1 ]]; then G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[0;34m'; BD='\033[1m'; X='\033[0m'; else G=''; R=''; Y=''; B=''; BD=''; X=''; fi
pass(){ echo -e "${G}[PASS]${X} $*"; }
info(){ echo -e "${B}[INFO]${X} $*"; }
warn(){ local m="$*"; WARNINGS=$((WARNINGS+1)); WARNING_MESSAGES+=("$m"); echo -e "${Y}[WARN]${X} $m"; }
fail(){ local m="$*"; ERRORS=$((ERRORS+1)); ERROR_MESSAGES+=("$m"); echo -e "${R}[FAIL]${X} $m"; }
action(){ local m="$*"; IMPORTANT_ACTIONS+=("$m"); echo -e "${B}[INFO]${X} $m"; }
section(){ echo; echo -e "${BD}==============================================================================${X}"; echo -e "${BD}$*${X}"; echo -e "${BD}==============================================================================${X}"; }
has(){ command -v "$1" >/dev/null 2>&1; }
reject_symlink(){ [[ -L "$1" ]] && { fail "Refusing symbolic-link destination: $1"; exit 1; }; }
secure_dir(){ reject_symlink "$1"; install -d -o root -g root -m "$2" "$1"; }
backup_once(){ local f="$1" n; [[ -e "$f" ]] || return 0; n="$(printf '%s' "$f"|sed 's#^/##;s#/#_#g')"; reject_symlink "$BACKUP_DIR/$n.original"; if [[ ! -e "$BACKUP_DIR/$n.original" ]]; then cp -a -- "$f" "$BACKUP_DIR/$n.original"; chown root:root "$BACKUP_DIR/$n.original"; pass "Created original backup of $f."; fi; }
pending(){ apt list --upgradable 2>/dev/null|awk 'NR>1{n++}END{print n+0}'; }

finding_help(){
  case "$1" in
    *NTP*|*clock*synchron*) echo "Check: timedatectl status"; echo "Fix:   sudo timedatectl set-ntp true" ;;
    *repository*DNS*) echo "Check: getent hosts archive.raspberrypi.com"; echo "Fix:   Verify DNS, gateway, and Internet connectivity." ;;
    *update\(s\)*remain*|*updates*remain*) echo "Check: apt list --upgradable 2>/dev/null" ;;
    *TUN*|*/dev/net/tun*) echo "Check: ls -l /dev/net/tun"; echo "Fix:   sudo modprobe tun" ;;
    *journal*) echo "Check: journalctl --header | head"; echo "Check: journalctl --list-boots" ;;
    *reboot*|*post-reboot*) echo "Check: sudo systemctl status $POST_UNIT_NAME"; echo "Logs:  sudo journalctl -u $POST_UNIT_NAME --no-pager" ;;
    *) echo "Log:   $LOG_FILE" ;;
  esac
}
print_actions(){ local i; ((${#IMPORTANT_ACTIONS[@]})) || return 0; section "IMPORTANT ACTIONS"; for ((i=0;i<${#IMPORTANT_ACTIONS[@]};i++)); do echo "[ACTION $((i+1))] ${IMPORTANT_ACTIONS[$i]}"; echo "Review: $UPGRADE_PLAN"; echo "Check:  sudo apt-get check && sudo dpkg --audit"; echo; done; }
print_findings(){ local i; ((WARNINGS||ERRORS)) || return 0; section "FINDINGS REQUIRING REVIEW"; for ((i=0;i<${#ERROR_MESSAGES[@]};i++)); do echo -e "${R}[FAIL $((i+1))]${X} ${ERROR_MESSAGES[$i]}"; finding_help "${ERROR_MESSAGES[$i]}"; echo; done; for ((i=0;i<${#WARNING_MESSAGES[@]};i++)); do echo -e "${Y}[WARN $((i+1))]${X} ${WARNING_MESSAGES[$i]}"; finding_help "${WARNING_MESSAGES[$i]}"; echo; done; echo "Full log: $LOG_FILE"; echo "Upgrade plan: $UPGRADE_PLAN"; }

case "$RESTART_DOMOTZ" in auto|true|false) ;; *) echo "RESTART_DOMOTZ must be auto, true, or false"; exit 1;; esac
[[ "$REBOOT_TIME" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "REBOOT_TIME must use HH:MM"; exit 1; }
[[ "$MIN_FREE_ROOT_MB" =~ ^[0-9]+$ ]] || { echo "MIN_FREE_ROOT_MB must be numeric"; exit 1; }
while (($#)); do case "$1" in --yolo) RUN_MODE=yolo; MODE_EXPLICIT=true;; --post-reboot) POST_REBOOT_RUN=true;; -h|--help) echo "Usage: domotz-pi-provisioner [--yolo]"; exit 0;; *) echo "Unknown option: $1"; exit 1;; esac; shift; done
[[ "$POST_REBOOT_RUN" == true ]] && { RUN_MODE=yolo; MODE_EXPLICIT=true; }
if [[ "$MODE_EXPLICIT" == false && -n "$RUN_MODE" ]]; then case "$RUN_MODE" in interactive|yolo) MODE_EXPLICIT=true;; *) echo "RUN_MODE must be interactive or yolo"; exit 1;; esac; fi
if [[ "$MODE_EXPLICIT" == false ]]; then [[ -t 0 ]] || { echo "Use an interactive terminal or --yolo."; exit 1; }; echo "Select provisioner mode:"; echo "  1) Interactive - prompt before package removals and reboot"; echo "  2) YOLO        - approve package removals and reboot automatically"; while true; do read -r -p "Mode [1/2]: " a; case "$a" in 1) RUN_MODE=interactive;break;;2) RUN_MODE=yolo;break;;*) echo "Enter 1 or 2.";;esac;done; fi
[[ $EUID -eq 0 ]] || { echo "Run with sudo or as root."; exit 1; }
has flock || { echo "flock is required."; exit 1; }
exec 9>"$LOCK_FILE"; flock -n 9 || { echo "Another provisioner instance is running."; exit 1; }
secure_dir "$LOG_DIR" 0750; secure_dir "$BACKUP_DIR" 0750; secure_dir "$STATE_DIR" 0750; secure_dir /etc/motd.d 0755
reject_symlink "$LOG_FILE"; touch "$LOG_FILE"; chown root:root "$LOG_FILE"; chmod 0640 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

section "PERSISTENT PROVISIONER COMMAND"
SELF="$(readlink -f "$0" 2>/dev/null||printf '%s' "$0")"; TARGET="$(readlink -f "$LAUNCHER" 2>/dev/null||printf '%s' "$LAUNCHER")"; reject_symlink "$LAUNCHER"
[[ "$SELF" == "$TARGET" ]] && pass "Running from persistent command: $LAUNCHER" || { install -o root -g root -m 0755 "$SELF" "$LAUNCHER"; pass "Installed persistent command: $LAUNCHER"; }
section "DOMOTZ PI PROVISIONER"
info "Version: $SCRIPT_VERSION"; info "Run mode: $RUN_MODE"; info "Post-reboot run: $POST_REBOOT_RUN"; info "Hostname: $(hostname)"

section "PERSISTENT SYSTEM JOURNAL"
if [[ ! -d /var/log/journal ]]; then install -d -o root -g systemd-journal -m 2755 /var/log/journal; pass "Created persistent system journal directory."; else pass "Persistent system journal directory exists."; fi
systemd-tmpfiles --create --prefix /var/log/journal >/dev/null 2>&1 && pass "Persistent journal permissions validated." || warn "Unable to validate persistent journal permissions."
journalctl --flush >/dev/null 2>&1 && pass "System journal flushed to persistent storage." || warn "Unable to flush system journal to persistent storage."

section "OPERATING SYSTEM VALIDATION"
if [[ -r /etc/os-release ]]; then . /etc/os-release; info "Operating system: ${PRETTY_NAME:-Unknown}"; [[ "${ID:-}" =~ ^(debian|raspbian)$ ]]&&pass "Supported Debian-family OS detected."||warn "OS does not identify as Debian or Raspbian."; fi
ARCH="$(dpkg --print-architecture 2>/dev/null||uname -m)"; info "Architecture: $ARCH"
getent hosts deb.debian.org >/dev/null 2>&1&&pass "DNS resolution works."||{ fail "DNS resolution failed."; print_findings; exit 1; }
getent hosts archive.raspberrypi.com >/dev/null 2>&1&&pass "Raspberry Pi repository DNS works."||warn "Raspberry Pi repository DNS check failed."
[[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null||true)" == yes ]]&&pass "System clock reports synchronized."||warn "System clock does not report NTP synchronization."

section "PACKAGE HEALTH AND UPDATE PLAN"
AUDIT="$(dpkg --audit 2>/dev/null||true)"; [[ -z "$AUDIT" ]]&&pass "dpkg audit clean."||{ fail "dpkg reports incomplete package operations."; echo "$AUDIT"; print_findings; exit 1; }
apt-get check >/dev/null 2>&1&&pass "APT dependency check passed."||{ fail "APT dependency check failed."; print_findings; exit 1; }
apt-get update&&pass "APT metadata refreshed."||{ fail "apt-get update failed."; print_findings; exit 1; }
PENDING_BEFORE="$(pending)"; info "Pending updates before upgrade: $PENDING_BEFORE"
FREE_KB="$(df -Pk /|awk 'NR==2{print $4}')"; FREE_MB=$((FREE_KB/1024)); info "Root free space: $FREE_MB MiB"; ((FREE_MB>=MIN_FREE_ROOT_MB))&&pass "Disk-space preflight passed."||{ fail "Insufficient free disk space."; print_findings; exit 1; }
reject_symlink "$UPGRADE_PLAN"; apt-get --simulate full-upgrade >"$UPGRADE_PLAN" 2>&1&&pass "Full-upgrade simulation completed."||{ fail "Full-upgrade simulation failed."; print_findings; exit 1; }; chmod 0640 "$UPGRADE_PLAN"; chown root:root "$UPGRADE_PLAN"
REMOVALS="$(grep -c '^Remv ' "$UPGRADE_PLAN"||true)"; info "Proposed package removals: $REMOVALS"
if ((REMOVALS)); then grep '^Remv ' "$UPGRADE_PLAN"; if [[ "$RUN_MODE" == yolo ]]; then action "YOLO mode automatically approved $REMOVALS proposed package removals."; else read -r -p "Allow these package removals and continue? [y/N]: " a; [[ "$a" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]&&action "Package removals explicitly approved."||{ fail "Package removals were not approved; provisioning stopped."; print_findings; exit 1; }; fi; fi

section "INITIAL SYSTEM UPDATE"
if ((PENDING_BEFORE)); then DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::="--force-confold" full-upgrade&&pass "Full system update completed."||{ fail "Full system update failed."; print_findings; exit 1; }; else pass "System is already up to date."; fi
PENDING_AFTER="$(pending)"; ((PENDING_AFTER==0))&&pass "No updates remain pending."||warn "$PENDING_AFTER update(s) remain pending."

section "REQUIRED PACKAGES AND DOMOTZ"
DEBIAN_FRONTEND=noninteractive apt-get install -y snapd unattended-upgrades ca-certificates&&pass "Required packages installed."||{ fail "Required package installation failed."; print_findings; exit 1; }
systemctl enable --now snapd.socket >/dev/null 2>&1&&pass "snapd.socket enabled."||fail "Unable to enable snapd.socket."
[[ -e /snap||! -d /var/lib/snapd/snap ]]||ln -s /var/lib/snapd/snap /snap
if snap list "$DOMOTZ_SNAP" >/dev/null 2>&1; then EXISTING=true; pass "Existing Domotz installation preserved."; else snap install "$DOMOTZ_SNAP"&&{ INSTALLED=true; pass "Domotz installed."; }||{ fail "Domotz installation failed."; print_findings; exit 1; }; fi
for i in firewall-control network-observe raw-usb shutdown system-observe; do p="$DOMOTZ_SNAP:$i"; snap connections "$DOMOTZ_SNAP" 2>/dev/null|awk -v t="$p" '$2==t&&$3!="-"{f=1}END{exit !f}'&&pass "$p is connected."||{ snap connect "$p"&&pass "$p connected."||fail "Unable to connect $p."; }; done
touch /etc/modules; grep -Eq '^[[:space:]]*tun([[:space:]]*#.*)?$' /etc/modules||echo tun >>/etc/modules; modprobe tun&&pass "TUN loaded."||fail "Unable to load TUN."; [[ -c /dev/net/tun ]]||warn "/dev/net/tun unavailable."
[[ "$INSTALLED" == true||"$RESTART_DOMOTZ" == true ]]&&{ snap restart "$DOMOTZ_SNAP"&&{ RESTARTED=true; pass "Domotz restarted."; }||fail "Domotz restart failed."; }||pass "Existing Domotz restart skipped to preserve remote access."
SERVICES="$(snap services "$DOMOTZ_SNAP" 2>/dev/null||true)"; printf '%s\n' "$SERVICES"|awk 'NR>1&&$3=="active"{f=1}END{exit !f}'&&pass "At least one Domotz service is active."||fail "No active Domotz service detected."

section "AUTOMATIC UPDATE POLICY"
backup_once "$AUTO_POLICY"; backup_once "$LOCAL_POLICY"
cat >"$AUTO_POLICY" <<'APT'
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT
cat >"$LOCAL_POLICY" <<APT
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
APT
chmod 0644 "$AUTO_POLICY" "$LOCAL_POLICY"; apt-config dump >/dev/null 2>&1&&pass "Automatic update policy validates."||fail "APT configuration parsing failed."
for t in apt-daily.timer apt-daily-upgrade.timer; do systemctl enable --now "$t" >/dev/null 2>&1&&pass "$t enabled."||fail "Unable to enable $t."; done

section "REBOOT STATUS"
if [[ -f /var/run/reboot-required ]]; then REBOOT_REQUIRED=true; warn "System updates require a reboot."; touch "$MARKER"; if [[ "$RUN_MODE" == yolo&&"$POST_REBOOT_RUN" == false ]]; then cat >"$POST_UNIT" <<UNIT
[Unit]
Description=Complete Domotz Pi Provisioning After Reboot
Wants=network-online.target
After=network-online.target
ConditionPathExists=$MARKER
[Service]
Type=oneshot
ExecStart=$LAUNCHER --yolo --post-reboot
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload; systemctl enable "$POST_UNIT_NAME" >/dev/null 2>&1; pass "Installed one-time automatic post-reboot validation service."; elif [[ "$POST_REBOOT_RUN" == true ]]; then warn "Automatic post-reboot validation still reports a reboot requirement; reboot loop prevented."; fi; cat >"$MOTD" <<MOTD
*** DOMOTZ PI PROVISIONING INCOMPLETE ***
Run: sudo domotz-pi-provisioner
Status: sudo systemctl status $POST_UNIT_NAME
Logs: sudo journalctl -u $POST_UNIT_NAME --no-pager
MOTD
else pass "No reboot required."; if [[ -f "$MARKER" ]]; then rm -f "$MARKER" "$MOTD" "$POST_UNIT"; systemctl disable "$POST_UNIT_NAME" >/dev/null 2>&1||true; systemctl daemon-reload; pass "Post-reboot validation complete; temporary reminder and service removed."; fi; fi

section "FINAL DEPLOYMENT REPORT"
printf 'Version:             %s\nRun mode:            %s\nPost-reboot run:     %s\nHostname:            %s\nArchitecture:        %s\nUpdates before:      %s\nUpdates remaining:   %s\nExisting collector:  %s\nInstalled this run:  %s\nDomotz restarted:    %s\nReboot required:     %s\nErrors:              %s\nWarnings:            %s\n' "$SCRIPT_VERSION" "$RUN_MODE" "$POST_REBOOT_RUN" "$(hostname)" "$ARCH" "$PENDING_BEFORE" "$PENDING_AFTER" "$EXISTING" "$INSTALLED" "$RESTARTED" "$REBOOT_REQUIRED" "$ERRORS" "$WARNINGS"
print_actions; print_findings
section "FINAL STATUS"
if ((ERRORS==0)); then echo -e "${G}${BD}DOMOTZ PI PROVISIONER VALIDATION PASSED${X}"; ((WARNINGS))&&echo "Validation passed with $WARNINGS warning(s). Review the findings summary above."; if [[ "$REBOOT_REQUIRED" == true ]]; then if [[ "$RUN_MODE" == yolo&&"$POST_REBOOT_RUN" == false ]]; then warn "YOLO mode approved the required reboot. Rebooting now."; sync; systemctl reboot; elif [[ "$POST_REBOOT_RUN" == true ]]; then warn "No additional automatic reboot will be performed. Review the findings and MOTD."; else read -r -p "Reboot required. Reboot now? [y/N]: " a; [[ "$a" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]&&{ sync;systemctl reboot; }||info "Reboot deferred."; fi; fi; exit 0; else echo -e "${R}${BD}DOMOTZ PI PROVISIONER VALIDATION FAILED${X}"; exit 1; fi
