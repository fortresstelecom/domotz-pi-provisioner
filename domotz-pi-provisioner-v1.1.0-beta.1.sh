#!/usr/bin/env bash
# Domotz Pi Provisioner v1.1.0-beta.1
# Beta: transactional NetworkManager -> systemd-networkd migration + dynavlan
set -u
set -o pipefail
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'; export PATH
umask 027

VERSION='1.1.0-beta.1'
MODE=''
POST_REBOOT=false
ROLLBACK_SECONDS="${ROLLBACK_SECONDS:-300}"
DYNAVLAN_VERSION="${DYNAVLAN_VERSION:-v0.3.0}"
DOMOTZ_SNAP='domotzpro-agent-publicstore'
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://portal.domotz.com/}"
LOG_DIR='/var/log/domotz-pi-provisioner'
LOG_FILE="$LOG_DIR/setup.log"
STATE_DIR='/var/lib/domotz-pi-provisioner'
MIGRATION_DIR="$STATE_DIR/network-migration"
BACKUP_ARCHIVE="$MIGRATION_DIR/network-backup.tar.gz"
ROLLBACK_SCRIPT='/usr/local/sbin/domotz-network-rollback'
ROLLBACK_UNIT='domotz-network-migration-rollback'
BASE_NETPLAN='/etc/netplan/01-domotz-uplink.yaml'
LAUNCHER='/usr/local/sbin/domotz-pi-provisioner'
ERRORS=0; WARNINGS=0
MIGRATION_REQUIRED=false; MIGRATION_COMMITTED=false; DYNAVLAN_INSTALLED=false
MGMT_IF=''; MGMT_IP=''; MGMT_PREFIX=''; MGMT_GW=''; MGMT_CONN=''; IPV4_METHOD=''; DNS_SERVERS=''
ROLLBACK_EPOCH=0; ROLLBACK_TEXT=''
WARNINGS_LIST=(); ERRORS_LIST=()

if [[ -t 1 ]]; then G='\033[0;32m'; R='\033[0;31m'; Y='\033[1;33m'; B='\033[0;34m'; BD='\033[1m'; X='\033[0m'; else G='';R='';Y='';B='';BD='';X='';fi
pass(){ echo -e "${G}[PASS]${X} $*"; }
info(){ echo -e "${B}[INFO]${X} $*"; }
warn(){ WARNINGS=$((WARNINGS+1)); WARNINGS_LIST+=("$*"); echo -e "${Y}[WARN]${X} $*"; }
fail(){ ERRORS=$((ERRORS+1)); ERRORS_LIST+=("$*"); echo -e "${R}[FAIL]${X} $*"; }
section(){ echo; printf '%s\n%s\n%s\n' '==============================================================================' "$*" '=============================================================================='; }
need(){ command -v "$1" >/dev/null 2>&1 || { fail "Required command not found: $1"; return 1; }; }

usage(){ cat <<EOF
Usage: $0 [--yolo]

No argument  Prompt for Interactive or YOLO mode.
--yolo       Approve expected changes automatically after safety validation.

Environment overrides:
  ROLLBACK_SECONDS=300
  DYNAVLAN_VERSION=v0.3.0
  HEALTHCHECK_URL=https://portal.domotz.com/
EOF
}

while (($#)); do case "$1" in --yolo) MODE='yolo';; -h|--help) usage; exit 0;; *) echo "Unknown option: $1"; exit 2;; esac; shift; done
if [[ -z "$MODE" ]]; then
  [[ -t 0 ]] || { echo 'Run from an interactive terminal or use --yolo.'; exit 2; }
  echo 'Select provisioner mode:'; echo '  1) Interactive'; echo '  2) YOLO'
  while true; do read -r -p 'Mode [1/2]: ' answer; case "$answer" in 1) MODE='interactive';break;;2) MODE='yolo';break;;*) echo 'Enter 1 or 2.';;esac;done
fi
[[ $EUID -eq 0 ]] || { echo 'Run with sudo or as root.'; exit 1; }
install -d -o root -g root -m 0750 "$LOG_DIR" "$STATE_DIR" "$MIGRATION_DIR"
touch "$LOG_FILE"; chmod 0640 "$LOG_FILE"; exec > >(tee -a "$LOG_FILE") 2>&1
exec 9>/run/lock/domotz-pi-provisioner.lock; flock -n 9 || { echo 'Another provisioner instance is running.'; exit 1; }

snapshot_management(){
  MGMT_IF="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
  MGMT_GW="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')"
  MGMT_IP="$(ip -4 route get "${MGMT_GW:-1.1.1.1}" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')"
  MGMT_PREFIX="$(ip -o -4 addr show dev "$MGMT_IF" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[2]}')"
  MGMT_CONN="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$MGMT_IF" '$2==d{print $1;exit}')"
  IPV4_METHOD="$(nmcli -g ipv4.method connection show "$MGMT_CONN" 2>/dev/null || true)"
  DNS_SERVERS="$(nmcli -g IP4.DNS device show "$MGMT_IF" 2>/dev/null | sed '/^$/d' | paste -sd, -)"
  [[ -n "$MGMT_IF" && -n "$MGMT_IP" && -n "$MGMT_PREFIX" && -n "$MGMT_GW" && -n "$MGMT_CONN" ]] || return 1
}

preflight(){
  section 'NETWORK MIGRATION PREFLIGHT'
  local cmd
  for cmd in ip nmcli netplan systemctl curl tar ping date awk sed grep; do need "$cmd" || return 1; done
  dpkg --audit | grep -q . && { fail 'dpkg reports incomplete package operations.'; return 1; } || pass 'dpkg audit clean.'
  apt-get check >/dev/null 2>&1 && pass 'APT dependency check passed.' || { fail 'APT dependency check failed.'; return 1; }
  snapshot_management || { fail 'Unable to identify the complete management path.'; return 1; }
  info "Management connection: $MGMT_CONN"
  info "Management interface:  $MGMT_IF"
  info "Management address:    $MGMT_IP/$MGMT_PREFIX"
  info "Default gateway:       $MGMT_GW"
  info "IPv4 method:           $IPV4_METHOD"
  ping -c 2 -W 2 "$MGMT_GW" >/dev/null 2>&1 && pass 'Current gateway is reachable.' || { fail 'Current gateway is not reachable.'; return 1; }
  getent hosts portal.domotz.com >/dev/null 2>&1 && pass 'DNS resolution works.' || { fail 'DNS resolution failed.'; return 1; }
  curl -fsSIL --connect-timeout 10 --max-time 15 "$HEALTHCHECK_URL" >/dev/null && pass 'Domotz HTTPS preflight succeeded.' || { fail 'Domotz HTTPS preflight failed.'; return 1; }
  case "$IPV4_METHOD" in auto|manual) ;; *) fail "Unsupported IPv4 method for beta migration: $IPV4_METHOD"; return 1;; esac
}

backup_network(){
  section 'NETWORK CONFIGURATION BACKUP'
  rm -f "$BACKUP_ARCHIVE"
  tar -czf "$BACKUP_ARCHIVE" --ignore-failed-read \
    /etc/netplan /etc/NetworkManager/system-connections /etc/systemd/network 2>/dev/null
  chmod 0600 "$BACKUP_ARCHIVE"
  tar -tzf "$BACKUP_ARCHIVE" >/dev/null 2>&1 && pass "Network backup created: $BACKUP_ARCHIVE" || { fail 'Network backup validation failed.'; return 1; }
}

write_rollback_script(){
  cat >"$ROLLBACK_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
LOG='$LOG_FILE'
BACKUP='$BACKUP_ARCHIVE'
exec >>"\$LOG" 2>&1
echo "[WARN] Automatic network rollback started at \$(date '+%B %-d, %Y at %-I:%M:%S %p %Z')."
[[ -f "\$BACKUP" ]] || { echo '[FAIL] Network rollback backup is missing.'; exit 1; }
rm -rf /etc/netplan /etc/NetworkManager/system-connections /etc/systemd/network
mkdir -p /
tar -xzf "\$BACKUP" -C /
systemctl disable --now systemd-networkd.service systemd-networkd-wait-online.service 2>/dev/null || true
systemctl unmask NetworkManager.service 2>/dev/null || true
systemctl enable --now NetworkManager.service
netplan generate
netplan apply
sleep 8
if ping -c 2 -W 2 '$MGMT_GW' >/dev/null 2>&1; then
  echo '[PASS] Original NetworkManager configuration restored and gateway reachable.'
else
  echo '[FAIL] Rollback applied, but the original gateway is not reachable.'
fi
EOF
  chmod 0700 "$ROLLBACK_SCRIPT"
}

arm_rollback(){
  local now
  write_rollback_script
  now="$(date +%s)"; ROLLBACK_EPOCH=$((now + ROLLBACK_SECONDS))
  ROLLBACK_TEXT="$(date -d "@$ROLLBACK_EPOCH" '+%B %-d, %Y at %-I:%M:%S %p %Z')"
  systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemd-run --unit="$ROLLBACK_UNIT" --on-active="${ROLLBACK_SECONDS}s" "$ROLLBACK_SCRIPT" >/dev/null
  pass "Automatic rollback armed for $ROLLBACK_SECONDS seconds."
  info "Rollback scheduled: $ROLLBACK_TEXT"
}

disarm_rollback(){
  systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemctl reset-failed "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  MIGRATION_COMMITTED=true
  pass 'Automatic rollback canceled; network migration committed.'
}

write_networkd_netplan(){
  local addresses gateway dns_yaml=''
  rm -f /etc/netplan/*.yaml
  if [[ "$IPV4_METHOD" == auto ]]; then
    cat >"$BASE_NETPLAN" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $MGMT_IF:
      dhcp4: true
      dhcp6: true
      optional: false
EOF
  else
    addresses="$(nmcli -g ipv4.addresses connection show "$MGMT_CONN" | tr ',' '\n' | sed '/^$/d' | sed 's/^/          - /')"
    [[ -n "$DNS_SERVERS" ]] && dns_yaml="      nameservers:\n        addresses: [${DNS_SERVERS}]"
    cat >"$BASE_NETPLAN" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    $MGMT_IF:
      addresses:
$addresses
      routes:
        - to: default
          via: $MGMT_GW
$(printf '%b' "$dns_yaml")
      optional: false
EOF
  fi
  chmod 0600 "$BASE_NETPLAN"
  netplan generate
}

apply_migration(){
  section 'NETWORKMANAGER TO SYSTEMD-NETWORKD MIGRATION'
  write_networkd_netplan || return 1
  systemctl enable systemd-networkd.service systemd-networkd-wait-online.service >/dev/null
  systemctl disable NetworkManager.service >/dev/null 2>&1 || true
  info 'Applying systemd-networkd configuration. The current SSH session may briefly reset.'
  netplan apply
  sleep 12
}

postflight(){
  section 'POST-MIGRATION HEALTH VALIDATION'
  local failures=0 current_if current_gw current_src
  current_if="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
  current_gw="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')"
  current_src="$(ip -4 route get "$MGMT_GW" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')"
  [[ "$current_if" == "$MGMT_IF" ]] && pass 'Management interface preserved.' || { fail "Management interface changed: $current_if"; failures=$((failures+1)); }
  [[ "$current_gw" == "$MGMT_GW" ]] && pass 'Default gateway preserved.' || { fail "Default gateway changed: $current_gw"; failures=$((failures+1)); }
  [[ "$current_src" == "$MGMT_IP" ]] && pass 'Management IPv4 address preserved.' || { fail "Management source address changed: $current_src"; failures=$((failures+1)); }
  systemctl is-active --quiet systemd-networkd && pass 'systemd-networkd is active.' || { fail 'systemd-networkd is inactive.'; failures=$((failures+1)); }
  ping -c 3 -W 2 "$MGMT_GW" >/dev/null 2>&1 && pass 'Gateway is reachable.' || { fail 'Gateway is unreachable.'; failures=$((failures+1)); }
  getent hosts portal.domotz.com >/dev/null 2>&1 && pass 'DNS resolution works.' || { fail 'DNS resolution failed.'; failures=$((failures+1)); }
  curl -fsSIL --connect-timeout 10 --max-time 15 "$HEALTHCHECK_URL" >/dev/null && pass 'Domotz HTTPS connectivity works.' || { fail 'Domotz HTTPS connectivity failed.'; failures=$((failures+1)); }
  systemctl is-active --quiet ssh && ss -ltnH | grep -qE ':[[:digit:]]*22[[:space:]]' && pass 'SSH is active and listening.' || { fail 'SSH validation failed.'; failures=$((failures+1)); }
  snap services "$DOMOTZ_SNAP" 2>/dev/null | awk 'NR>1&&$3=="active"{f=1}END{exit !f}' && pass 'Domotz service is active.' || warn 'Domotz service is not yet active.'
  ((failures == 0))
}

interactive_commit(){
  section 'NETWORK MIGRATION SAFETY WINDOW'
  echo 'Automatic rollback is ARMED.'
  echo "Rollback at: $ROLLBACK_TEXT"
  echo 'Press Y to keep the changes, or N to revert now.'
  local remaining response
  while true; do
    remaining=$((ROLLBACK_EPOCH - $(date +%s)))
    ((remaining > 0)) || { echo; fail 'Confirmation window expired; rollback is running.'; return 1; }
    printf '\rTime remaining: %02d:%02d  Keep changes? [y/N]: ' $((remaining/60)) $((remaining%60))
    if IFS= read -r -t 1 -n 1 response; then
      case "$response" in
        y|Y) echo; disarm_rollback; return 0;;
        n|N|'') echo; "$ROLLBACK_SCRIPT"; systemctl stop "$ROLLBACK_UNIT.timer" >/dev/null 2>&1 || true; return 1;;
      esac
    fi
  done
}

install_dynavlan(){
  section 'DYNAVLAN INSTALLATION'
  local installer='/tmp/dynavlan-get.sh'
  curl -fsSL 'https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh' -o "$installer" || { fail 'Unable to download dynavlan installer.'; return 1; }
  chmod 0700 "$installer"
  bash "$installer" "$DYNAVLAN_VERSION" || { fail 'dynavlan installation failed.'; return 1; }
  command -v dynavlan >/dev/null 2>&1 || { fail 'dynavlan command was not installed.'; return 1; }
  if grep -q '^#*RESTART_SNAPS=' /etc/dynavlan.conf; then
    sed -Ei 's|^#*RESTART_SNAPS=.*|RESTART_SNAPS="domotzpro-agent-publicstore"|' /etc/dynavlan.conf
  else
    printf '\nRESTART_SNAPS="domotzpro-agent-publicstore"\n' >>/etc/dynavlan.conf
  fi
  dynavlan --version
  dynavlan --dry-run || { fail 'dynavlan dry-run failed.'; return 1; }
  DYNAVLAN_INSTALLED=true
  pass 'dynavlan installed and configured for Domotz restart integration.'
  warn 'Beta does not automatically run dynavlan --boot; perform the first apply attended after reviewing the dry-run.'
}

section "DOMOTZ PI PROVISIONER $VERSION"
info "Mode: $MODE"
install -o root -g root -m 0755 "$0" "$LAUNCHER"

if systemctl is-active --quiet NetworkManager; then MIGRATION_REQUIRED=true; fi
if [[ "$MIGRATION_REQUIRED" == true ]]; then
  preflight || { section 'PROVISIONING STOPPED'; echo 'Network migration preflight failed. No APT updates or dynavlan changes were attempted.'; exit 1; }
  if [[ "$MODE" == interactive ]]; then
    echo
    echo 'This existing collector uses NetworkManager.'
    echo 'Migration may briefly interrupt SSH or Domotz Remote Access.'
    read -r -p 'Migrate to systemd-networkd with automatic rollback protection? [y/N]: ' answer
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]] || { info 'Network migration declined. Provisioning stopped before updates.'; exit 0; }
  fi
  backup_network || exit 1
  arm_rollback || exit 1
  if ! apply_migration || ! postflight; then
    section 'NETWORK MIGRATION FAILED'
    echo "Rollback at: $ROLLBACK_TEXT"
    echo 'The provisioner will not continue into APT updates, dynavlan, or other configuration.'
    echo 'Automatic rollback remains armed.'
    exit 1
  fi
  if [[ "$MODE" == yolo ]]; then disarm_rollback; else interactive_commit || { section 'PROVISIONING STOPPED'; echo 'Network changes were not committed. No later configuration was attempted.'; exit 1; }; fi
else
  pass 'systemd-networkd is already the active network renderer; migration not required.'
fi

section 'PACKAGE UPDATE'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
apt-get check >/dev/null
pass 'APT update and full-upgrade completed.'

install_dynavlan || exit 1

section 'FINAL REPORT'
printf 'Version:               %s\nMode:                  %s\nNetwork migrated:      %s\nMigration committed:   %s\nRollback timeout:      %s seconds\nDynavlan installed:    %s\nErrors:                %s\nWarnings:              %s\n' "$VERSION" "$MODE" "$MIGRATION_REQUIRED" "$MIGRATION_COMMITTED" "$ROLLBACK_SECONDS" "$DYNAVLAN_INSTALLED" "$ERRORS" "$WARNINGS"
echo
pass 'BETA PROVISIONING COMPLETED.'
echo 'Next attended step: sudo dynavlan --boot'
