#!/usr/bin/env bash
# Domotz Pi Provisioner v1.1.0-beta.2
# Transactional NetworkManager -> systemd-networkd migration and dynavlan integration.
set -u
set -o pipefail
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'; export PATH
umask 027

VERSION='1.1.0-beta.2'
MODE=''
ACTION='provision'
ROLLBACK_SECONDS="${ROLLBACK_SECONDS:-300}"
DYNAVLAN_VERSION="${DYNAVLAN_VERSION:-v0.3.0}"
DOMOTZ_SNAP='domotzpro-agent-publicstore'
HEALTHCHECK_URL="${HEALTHCHECK_URL:-https://portal.domotz.com/}"
LOG_DIR='/var/log/domotz-pi-provisioner'
LOG_FILE="$LOG_DIR/setup.log"
STATE_DIR='/var/lib/domotz-pi-provisioner'
MIGRATION_DIR="$STATE_DIR/network-migration"
STATE_FILE="$MIGRATION_DIR/state"
BACKUP_ARCHIVE="$MIGRATION_DIR/network-backup.tar.gz"
ROLLBACK_SCRIPT='/usr/local/sbin/domotz-network-rollback'
ROLLBACK_UNIT='domotz-network-migration-rollback'
BASE_NETPLAN='/etc/netplan/01-domotz-uplink.yaml'
LAUNCHER='/usr/local/sbin/domotz-pi-provisioner'
ERRORS=0; WARNINGS=0
MIGRATION_REQUIRED=false; MIGRATION_COMMITTED=false; DYNAVLAN_INSTALLED=false
MGMT_IF=''; MGMT_MAC=''; MGMT_IP=''; MGMT_PREFIX=''; MGMT_GW=''; MGMT_CONN=''; IPV4_METHOD=''; DNS_SERVERS=''
POST_IP=''; ROLLBACK_EPOCH=0; ROLLBACK_TEXT=''

if [[ -t 1 ]]; then G='\033[0;32m';R='\033[0;31m';Y='\033[1;33m';B='\033[0;34m';BD='\033[1m';X='\033[0m';else G='';R='';Y='';B='';BD='';X='';fi
pass(){ echo -e "${G}[PASS]${X} $*"; }
info(){ echo -e "${B}[INFO]${X} $*"; }
warn(){ WARNINGS=$((WARNINGS+1)); echo -e "${Y}[WARN]${X} $*"; }
fail(){ ERRORS=$((ERRORS+1)); echo -e "${R}[FAIL]${X} $*"; }
section(){ echo; printf '%s\n%s\n%s\n' '==============================================================================' "$*" '=============================================================================='; }
need(){ command -v "$1" >/dev/null 2>&1 || { fail "Required command not found: $1"; return 1; }; }

usage(){ cat <<EOF
Usage: $0 [--yolo] [--commit-network-migration|--rollback-network-migration]

No argument                    Prompt for Interactive or YOLO mode.
--yolo                         Automatically approve validated changes.
--commit-network-migration     Commit a pending migration after reconnecting.
--rollback-network-migration   Immediately restore the saved network configuration.
EOF
}

while (($#)); do
  case "$1" in
    --yolo) MODE='yolo' ;;
    --commit-network-migration) ACTION='commit' ;;
    --rollback-network-migration) ACTION='rollback' ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || { echo 'Run with sudo or as root.'; exit 1; }
install -d -o root -g root -m 0750 "$LOG_DIR" "$STATE_DIR" "$MIGRATION_DIR"
touch "$LOG_FILE"; chmod 0640 "$LOG_FILE"; exec > >(tee -a "$LOG_FILE") 2>&1
exec 9>/run/lock/domotz-pi-provisioner.lock; flock -n 9 || { echo 'Another provisioner instance is running.'; exit 1; }

load_state(){ [[ -r "$STATE_FILE" ]] && . "$STATE_FILE"; }
cleanup_transient_units(){
  systemctl stop "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  systemctl reset-failed "$ROLLBACK_UNIT.timer" "$ROLLBACK_UNIT.service" >/dev/null 2>&1 || true
  rm -f "/run/systemd/transient/$ROLLBACK_UNIT.timer" "/run/systemd/transient/$ROLLBACK_UNIT.service"
  systemctl daemon-reload >/dev/null 2>&1 || true
}
commit_pending(){
  load_state
  [[ "${MIGRATION_PENDING:-false}" == true ]] || { echo 'No pending migration was found.'; exit 1; }
  cleanup_transient_units
  sed -i 's/^MIGRATION_PENDING=.*/MIGRATION_PENDING=false/' "$STATE_FILE"
  pass 'Pending network migration committed; automatic rollback canceled.'
  exit 0
}
rollback_now(){
  [[ -x "$ROLLBACK_SCRIPT" ]] || { echo "Rollback script not found: $ROLLBACK_SCRIPT"; exit 1; }
  cleanup_transient_units
  "$ROLLBACK_SCRIPT"
  exit $?
}
[[ "$ACTION" == commit ]] && commit_pending
[[ "$ACTION" == rollback ]] && rollback_now

if [[ -z "$MODE" ]]; then
  [[ -t 0 ]] || { echo 'Run from an interactive terminal or use --yolo.'; exit 2; }
  echo 'Select provisioner mode:'; echo '  1) Interactive'; echo '  2) YOLO'
  while true; do read -r -p 'Mode [1/2]: ' answer; case "$answer" in 1) MODE='interactive';break;;2) MODE='yolo';break;;*) echo 'Enter 1 or 2.';;esac;done
fi

choose_rollback_window(){
  [[ "$MODE" == interactive ]] || return 0
  local choice minutes
  echo; echo 'Select automatic rollback window:'
  echo '  1) 3 minutes'; echo '  2) 5 minutes'; echo '  3) 10 minutes'; echo '  4) 15 minutes'; echo '  5) Custom'
  read -r -p 'Rollback window [1-5, default 2]: ' choice
  case "${choice:-2}" in
    1) ROLLBACK_SECONDS=180;; 2) ROLLBACK_SECONDS=300;; 3) ROLLBACK_SECONDS=600;; 4) ROLLBACK_SECONDS=900;;
    5) read -r -p 'Custom rollback window in minutes [3-30]: ' minutes; [[ "$minutes" =~ ^[0-9]+$ ]] && ((minutes>=3 && minutes<=30)) || { fail 'Custom rollback window must be 3-30 minutes.'; return 1; }; ROLLBACK_SECONDS=$((minutes*60));;
    *) fail 'Invalid rollback-window selection.'; return 1;;
  esac
}

snapshot_management(){
  MGMT_IF="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
  MGMT_GW="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')"
  MGMT_IP="$(ip -4 route get "${MGMT_GW:-1.1.1.1}" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')"
  MGMT_PREFIX="$(ip -o -4 addr show dev "$MGMT_IF" scope global 2>/dev/null | awk 'NR==1{split($4,a,"/");print a[2]}')"
  MGMT_MAC="$(cat "/sys/class/net/$MGMT_IF/address" 2>/dev/null || true)"
  MGMT_CONN="$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | awk -F: -v d="$MGMT_IF" '$2==d{print $1;exit}')"
  IPV4_METHOD="$(nmcli -g ipv4.method connection show "$MGMT_CONN" 2>/dev/null || true)"
  DNS_SERVERS="$(nmcli -g IP4.DNS device show "$MGMT_IF" 2>/dev/null | sed '/^$/d' | paste -sd, -)"
  [[ -n "$MGMT_IF" && -n "$MGMT_MAC" && -n "$MGMT_IP" && -n "$MGMT_PREFIX" && -n "$MGMT_GW" && -n "$MGMT_CONN" ]]
}

preflight(){
  section 'NETWORK MIGRATION PREFLIGHT'
  local cmd
  for cmd in ip nmcli netplan networkctl systemctl curl tar ping date awk sed grep ss; do need "$cmd" || return 1; done
  dpkg --audit | grep -q . && { fail 'dpkg reports incomplete package operations.'; return 1; } || pass 'dpkg audit clean.'
  apt-get check >/dev/null 2>&1 && pass 'APT dependency check passed.' || { fail 'APT dependency check failed.'; return 1; }
  snapshot_management || { fail 'Unable to identify the complete management path.'; return 1; }
  info "Management connection: $MGMT_CONN"; info "Management interface:  $MGMT_IF"; info "MAC address:           $MGMT_MAC"
  info "Management address:    $MGMT_IP/$MGMT_PREFIX"; info "Default gateway:       $MGMT_GW"; info "IPv4 method:           $IPV4_METHOD"
  ping -c 2 -W 2 "$MGMT_GW" >/dev/null 2>&1 && pass 'Current gateway is reachable.' || { fail 'Current gateway is not reachable.'; return 1; }
  getent hosts portal.domotz.com >/dev/null 2>&1 && pass 'DNS resolution works.' || { fail 'DNS resolution failed.'; return 1; }
  curl -fsSIL --connect-timeout 10 --max-time 15 "$HEALTHCHECK_URL" >/dev/null && pass 'Domotz HTTPS preflight succeeded.' || { fail 'Domotz HTTPS preflight failed.'; return 1; }
  case "$IPV4_METHOD" in auto|manual) ;; *) fail "Unsupported IPv4 method: $IPV4_METHOD"; return 1;; esac
  [[ -f /lib/netplan/00-network-manager-all.yaml ]] && chmod 0600 /lib/netplan/00-network-manager-all.yaml
}

migration_warning(){
  local minutes=$((ROLLBACK_SECONDS/60))
  section 'NETWORK MIGRATION WARNING'
  echo 'This collector currently uses NetworkManager and will be migrated to systemd-networkd.'
  echo; echo 'IMPORTANT: The DHCP IP address MAY CHANGE during this migration.'; echo
  printf '  Interface:       %s\n  MAC address:     %s\n  Current IP:      %s/%s\n  Default gateway: %s\n  Rollback window: %s minutes\n' "$MGMT_IF" "$MGMT_MAC" "$MGMT_IP" "$MGMT_PREFIX" "$MGMT_GW" "$minutes"
  echo; echo 'If SSH disconnects, locate the MAC address in the switch, firewall, DHCP lease table, or ARP table.'
  echo "After reconnecting, commit with: sudo $LAUNCHER --commit-network-migration"
  echo 'Automatic rollback will be armed before network changes are applied.'
}

backup_network(){
  section 'NETWORK CONFIGURATION BACKUP'
  rm -f "$BACKUP_ARCHIVE"
  tar -czf "$BACKUP_ARCHIVE" --ignore-failed-read /etc/netplan /etc/NetworkManager/system-connections /etc/systemd/network 2>/dev/null
  chmod 0600 "$BACKUP_ARCHIVE"
  tar -tzf "$BACKUP_ARCHIVE" >/dev/null 2>&1 && pass "Network backup created: $BACKUP_ARCHIVE" || { fail 'Network backup validation failed.'; return 1; }
}

write_rollback_script(){
  cat >"$ROLLBACK_SCRIPT" <<EOF
#!/usr/bin/env bash
set -u
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
LOG='$LOG_FILE'; BACKUP='$BACKUP_ARCHIVE'; STATE='$STATE_FILE'; GW='$MGMT_GW'; IFACE='$MGMT_IF'; IP='$MGMT_IP'
exec >>"\$LOG" 2>&1
echo "[WARN] Rollback STARTED at \$(date '+%B %-d, %Y at %-I:%M:%S %p %Z')."
[[ -f "\$BACKUP" ]] || { echo '[FAIL] Rollback backup is missing.'; exit 1; }
rm -rf /etc/netplan /etc/NetworkManager/system-connections /etc/systemd/network
mkdir -p /etc
 tar -xzf "\$BACKUP" -C /
[[ -f /lib/netplan/00-network-manager-all.yaml ]] && chmod 0600 /lib/netplan/00-network-manager-all.yaml
systemctl unmask NetworkManager.service 2>/dev/null || true
systemctl enable NetworkManager.service >/dev/null 2>&1 || true
netplan generate
netplan apply || true
systemctl disable --now systemd-networkd-wait-online.service systemd-networkd.service systemd-networkd.socket 2>/dev/null || true
systemctl restart NetworkManager.service
sleep 12
failures=0
systemctl is-active --quiet NetworkManager || { echo '[FAIL] NetworkManager is inactive.'; failures=\$((failures+1)); }
systemctl is-active --quiet systemd-networkd && { echo '[FAIL] systemd-networkd remains active.'; failures=\$((failures+1)); } || echo '[PASS] systemd-networkd is inactive.'
current_ip=\$(ip -4 route get "\$GW" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if(\$i=="src"){print \$(i+1);exit}}')
[[ "\$current_ip" == "\$IP" ]] && echo '[PASS] Original management IP restored.' || { echo "[FAIL] Management IP is \$current_ip, expected \$IP."; failures=\$((failures+1)); }
ping -c 2 -W 2 "\$GW" >/dev/null 2>&1 && echo '[PASS] Original gateway reachable.' || { echo '[FAIL] Original gateway unreachable.'; failures=\$((failures+1)); }
if ((failures==0)); then echo '[PASS] Rollback VALIDATED and COMPLETE.'; sed -i 's/^MIGRATION_PENDING=.*/MIGRATION_PENDING=false/' "\$STATE" 2>/dev/null || true; exit 0; fi
echo '[FAIL] Rollback INCOMPLETE.'; exit 1
EOF
  chmod 0700 "$ROLLBACK_SCRIPT"
}

arm_rollback(){
  local now
  write_rollback_script
  now="$(date +%s)"; ROLLBACK_EPOCH=$((now + ROLLBACK_SECONDS)); ROLLBACK_TEXT="$(date -d "@$ROLLBACK_EPOCH" '+%B %-d, %Y at %-I:%M:%S %p %Z')"
  cat >"$STATE_FILE" <<EOF
MIGRATION_PENDING=true
MGMT_IF='$MGMT_IF'
MGMT_MAC='$MGMT_MAC'
MGMT_IP='$MGMT_IP'
MGMT_GW='$MGMT_GW'
ROLLBACK_EPOCH='$ROLLBACK_EPOCH'
ROLLBACK_TEXT='$ROLLBACK_TEXT'
EOF
  chmod 0600 "$STATE_FILE"
  cleanup_transient_units
  systemd-run --unit="$ROLLBACK_UNIT" --on-active="${ROLLBACK_SECONDS}s" "$ROLLBACK_SCRIPT" >/dev/null
  pass "Rollback ARMED for $ROLLBACK_SECONDS seconds."; info "Rollback scheduled: $ROLLBACK_TEXT"
}

disarm_rollback(){ cleanup_transient_units; sed -i 's/^MIGRATION_PENDING=.*/MIGRATION_PENDING=false/' "$STATE_FILE"; MIGRATION_COMMITTED=true; pass 'Rollback canceled; migration COMMITTED.'; }

write_networkd_netplan(){
  local addresses dns_yaml=''
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
      dhcp-identifier: mac
      optional: false
EOF
  else
    addresses="$(nmcli -g ipv4.addresses connection show "$MGMT_CONN" | tr ',' '\n' | sed '/^$/d;s/^/          - /')"
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
  chmod 0600 "$BASE_NETPLAN"; netplan generate
  if [[ "$IPV4_METHOD" == auto ]]; then grep -Rqs 'ClientIdentifier=mac' /run/systemd/network/ || warn 'Generated networkd configuration did not visibly contain ClientIdentifier=mac.'; fi
}

apply_migration(){
  section 'NETWORKMANAGER TO SYSTEMD-NETWORKD MIGRATION'
  write_networkd_netplan || return 1
  systemctl stop systemd-networkd.service systemd-networkd.socket >/dev/null 2>&1 || true
  systemctl enable systemd-networkd.service systemd-networkd-wait-online.service >/dev/null
  systemctl disable --now NetworkManager.service >/dev/null 2>&1 || true
  systemctl start systemd-networkd.service
  info 'Applying systemd-networkd configuration. SSH may disconnect and DHCP may assign another address.'
  netplan apply; sleep 12
}

postflight(){
  section 'POST-MIGRATION HEALTH VALIDATION'
  local failures=0 current_if current_gw
  current_if="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
  current_gw="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')"
  POST_IP="$(ip -4 route get "$MGMT_GW" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')"
  [[ "$current_if" == "$MGMT_IF" ]] && pass 'Management interface preserved.' || { fail "Management interface changed: $current_if"; failures=$((failures+1)); }
  [[ "$current_gw" == "$MGMT_GW" ]] && pass 'Default gateway preserved.' || { fail "Default gateway changed: $current_gw"; failures=$((failures+1)); }
  if [[ "$POST_IP" == "$MGMT_IP" ]]; then pass 'Management IPv4 address preserved.'; else warn "MANAGEMENT IP CHANGED: $MGMT_IP -> $POST_IP (MAC $MGMT_MAC)."; fi
  systemctl is-active --quiet systemd-networkd && pass 'systemd-networkd is active.' || { fail 'systemd-networkd is inactive.'; failures=$((failures+1)); }
  ping -c 3 -W 2 "$MGMT_GW" >/dev/null 2>&1 && pass 'Gateway is reachable.' || { fail 'Gateway is unreachable.'; failures=$((failures+1)); }
  getent hosts portal.domotz.com >/dev/null 2>&1 && pass 'DNS resolution works.' || { fail 'DNS resolution failed.'; failures=$((failures+1)); }
  curl -fsSIL --connect-timeout 10 --max-time 15 "$HEALTHCHECK_URL" >/dev/null && pass 'Domotz HTTPS connectivity works.' || { fail 'Domotz HTTPS connectivity failed.'; failures=$((failures+1)); }
  systemctl is-active --quiet ssh && ss -ltnH | grep -qE ':22[[:space:]]' && pass 'SSH is active and listening.' || { fail 'SSH validation failed.'; failures=$((failures+1)); }
  snap services "$DOMOTZ_SNAP" 2>/dev/null | awk 'NR>1&&$3=="active"{f=1}END{exit !f}' && pass 'Domotz service is active.' || warn 'Domotz service is not active.'
  ((failures==0))
}

interactive_commit(){
  section 'NETWORK MIGRATION SAFETY WINDOW'
  printf 'Interface:       %s\nMAC address:     %s\nOriginal IP:     %s\nCurrent IP:      %s\nRollback at:     %s\n' "$MGMT_IF" "$MGMT_MAC" "$MGMT_IP" "$POST_IP" "$ROLLBACK_TEXT"
  echo "If reconnected in another session, run: sudo $LAUNCHER --commit-network-migration"
  local remaining response
  while true; do
    remaining=$((ROLLBACK_EPOCH-$(date +%s)))
    ((remaining>0)) || { echo; fail 'Confirmation window expired; rollback is running.'; return 1; }
    printf '\rTime remaining: %02d:%02d  Keep changes? [y/N]: ' $((remaining/60)) $((remaining%60))
    if IFS= read -r -t 1 -n 1 response; then case "$response" in y|Y) echo; disarm_rollback; return 0;; n|N|'') echo; rollback_now;; esac; fi
  done
}

install_dynavlan(){
  section 'DYNAVLAN INSTALLATION'
  local installer='/tmp/dynavlan-get.sh'
  curl -fsSL 'https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh' -o "$installer" || { fail 'Unable to download dynavlan installer.'; return 1; }
  chmod 0700 "$installer"; bash "$installer" "$DYNAVLAN_VERSION" || { fail 'dynavlan installation failed.'; return 1; }
  command -v dynavlan >/dev/null || { fail 'dynavlan command missing after installation.'; return 1; }
  if grep -q '^#*RESTART_SNAPS=' /etc/dynavlan.conf; then sed -Ei 's|^#*RESTART_SNAPS=.*|RESTART_SNAPS="domotzpro-agent-publicstore"|' /etc/dynavlan.conf; else printf '\nRESTART_SNAPS="domotzpro-agent-publicstore"\n' >>/etc/dynavlan.conf; fi
  dynavlan --version; dynavlan --dry-run || { fail 'dynavlan dry-run failed.'; return 1; }
  DYNAVLAN_INSTALLED=true; pass 'dynavlan installed and configured.'; warn 'First dynavlan --boot remains attended during beta testing.'
}

section "DOMOTZ PI PROVISIONER $VERSION"
info "Mode: $MODE"; install -o root -g root -m 0755 "$0" "$LAUNCHER"
if systemctl is-active --quiet NetworkManager; then MIGRATION_REQUIRED=true; fi
if [[ "$MIGRATION_REQUIRED" == true ]]; then
  preflight || { section 'PROVISIONING STOPPED'; echo 'Preflight failed. No updates or dynavlan changes attempted.'; exit 1; }
  choose_rollback_window || exit 1
  migration_warning
  if [[ "$MODE" == interactive ]]; then read -r -p 'Proceed with migration? [y/N]: ' answer; [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]] || { info 'Migration declined. Provisioning stopped.'; exit 0; }; fi
  backup_network || exit 1; arm_rollback || exit 1
  if ! apply_migration || ! postflight; then section 'NETWORK MIGRATION FAILED'; echo "Rollback at: $ROLLBACK_TEXT"; echo 'Provisioning stopped; rollback remains armed.'; exit 1; fi
  if [[ "$MODE" == yolo ]]; then disarm_rollback; else interactive_commit || { section 'PROVISIONING STOPPED'; exit 1; }; fi
else
  pass 'NetworkManager is not active; renderer migration not required.'
fi

section 'PACKAGE UPDATE'
apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade && apt-get check >/dev/null || { fail 'APT update failed.'; exit 1; }
pass 'APT update and full-upgrade completed.'
install_dynavlan || exit 1
section 'FINAL REPORT'
printf 'Version:               %s\nMode:                  %s\nManagement interface:  %s\nMAC address:            %s\nOriginal IP:            %s\nPost-migration IP:      %s\nNetwork migrated:       %s\nMigration committed:    %s\nRollback timeout:       %s seconds\nDynavlan installed:     %s\nErrors:                 %s\nWarnings:               %s\n' "$VERSION" "$MODE" "${MGMT_IF:-unknown}" "${MGMT_MAC:-unknown}" "${MGMT_IP:-unknown}" "${POST_IP:-unchanged/not checked}" "$MIGRATION_REQUIRED" "$MIGRATION_COMMITTED" "$ROLLBACK_SECONDS" "$DYNAVLAN_INSTALLED" "$ERRORS" "$WARNINGS"
pass 'BETA PROVISIONING COMPLETED.'
echo 'Next attended step: sudo dynavlan --boot'
