#!/usr/bin/env bash
# Domotz Pi Provisioner v1.1.0-beta.4
# Transactional NetworkManager -> systemd-networkd migration and dynavlan integration.
set -u
set -o pipefail
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'; export PATH
umask 027

VERSION='1.1.0-beta.4'
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
LOGIN_NOTICE='/etc/profile.d/domotz-network-migration.sh'
DYNAVLAN_ACTIVATOR='/usr/local/sbin/domotz-dynavlan-activate'
DYNAVLAN_ACTIVATION_SERVICE='/etc/systemd/system/domotz-dynavlan-activate.service'
DYNAVLAN_ACTIVATION_TIMER='/etc/systemd/system/domotz-dynavlan-activate.timer'
DYNAVLAN_DISCOVERY_LOG="$LOG_DIR/dynavlan-discovery.log"
DYNAVLAN_APPLY_LOG="$LOG_DIR/dynavlan-apply.log"
DYNAVLAN_STATUS_LOG="$LOG_DIR/dynavlan-status.log"
DISCOVER_VLANS=false
DYNAVLAN_ACTIVATION='not-configured'
VLAN_MAX_SELECTED=1000
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
Usage: $0 [--yolo] [--discover-vlans] [--commit-network-migration|--rollback-network-migration]

No argument                    Prompt for Interactive or YOLO mode.
--yolo                         Automatically approve validated changes.
--commit-network-migration     Commit a pending migration after reconnecting.
--rollback-network-migration   Immediately restore the saved network configuration.
EOF
}

while (($#)); do
  case "$1" in
    --yolo) MODE='yolo' ;;
    --discover-vlans) DISCOVER_VLANS=true ;;
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
  rm -f "$LOGIN_NOTICE"
  pass 'Pending network migration committed; automatic rollback canceled.'
  exit 0
}
rollback_now(){
  [[ -x "$ROLLBACK_SCRIPT" ]] || { echo "Rollback script not found: $ROLLBACK_SCRIPT"; exit 1; }
  cleanup_transient_units
  "$ROLLBACK_SCRIPT"
  exit $?
}
pending_migration_menu(){
  load_state
  [[ "${MIGRATION_PENDING:-false}" == true ]] || return 1
  local remaining current_ip choice
  remaining=$(( ${ROLLBACK_EPOCH:-0} - $(date +%s) )); ((remaining < 0)) && remaining=0
  current_ip="$(ip -4 route get "${MGMT_GW:-1.1.1.1}" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}')"
  section 'PENDING NETWORK MIGRATION'
  printf 'Interface:       %s\nMAC address:     %s\nOriginal IP:     %s\nCurrent IP:      %s\nRollback at:     %s\nTime remaining:  %02d:%02d\n' "${MGMT_IF:-unknown}" "${MGMT_MAC:-unknown}" "${MGMT_IP:-unknown}" "${current_ip:-unknown}" "${ROLLBACK_TEXT:-unknown}" $((remaining/60)) $((remaining%60))
  echo; echo 'What would you like to do?'; echo '  K) Keep the new network configuration'; echo '  R) Restore the previous network configuration now'
  while true; do read -r -p 'Choice [K/R]: ' choice; case "$choice" in k|K) commit_pending;; r|R) rollback_now;; *) echo 'Enter K or R.';; esac; done
}
[[ "$ACTION" == commit ]] && commit_pending
[[ "$ACTION" == rollback ]] && rollback_now
if [[ "$ACTION" == provision && -r "$STATE_FILE" ]]; then
  pending_migration_menu || true
fi

if [[ -z "$MODE" ]]; then
  [[ -t 0 ]] || { echo 'Run from an interactive terminal or use --yolo.'; exit 2; }
  echo 'Select provisioner mode:'; echo '  1) Interactive'; echo '  2) YOLO'
  while true; do read -r -p 'Mode [1/2]: ' answer; case "$answer" in 1) MODE='interactive';break;;2) MODE='yolo';break;;*) echo 'Enter 1 or 2.';;esac;done
fi

choose_rollback_window(){
  [[ "$MODE" == interactive ]] || return 0
  local minutes
  echo
  while true; do
    read -r -p 'Rollback window in minutes [3-30, default 5]: ' minutes
    minutes="${minutes:-5}"
    if [[ "$minutes" =~ ^[0-9]+$ ]] && ((minutes >= 3 && minutes <= 30)); then
      ROLLBACK_SECONDS=$((minutes * 60))
      pass "Rollback window set to $minutes minutes."
      return 0
    fi
    warn 'Enter a whole number from 3 through 30.'
  done
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

ensure_network_migration_prerequisites(){
  section 'NETWORK MIGRATION PREREQUISITES'
  local packages=()

  command -v netplan >/dev/null 2>&1 || packages+=(netplan.io)

  if ((${#packages[@]} == 0)); then
    pass 'Required network migration packages are already installed.'
    return 0
  fi

  info "Installing required network migration package(s): ${packages[*]}"
  apt-get update || { fail 'Unable to refresh APT package lists for migration prerequisites.'; return 1; }
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}" || { fail 'Unable to install network migration prerequisites.'; return 1; }

  command -v netplan >/dev/null 2>&1 || { fail 'netplan is unavailable after installing netplan.io.'; return 1; }
  pass 'Network migration prerequisites installed and validated.'
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
  echo; echo 'If SSH disconnects, locate the device using the MAC address above and reconnect to its current IP address.'
  echo
  echo 'After reconnecting, run:'
  echo
  echo '  sudo domotz-pi-provisioner'
  echo
  echo 'to confirm the networking update.'
  echo
  echo 'Your next login will display the migration status and the next steps.'
  echo 'If the migration is not confirmed before the rollback timer expires,'
  echo 'the previous network configuration will be restored automatically.'
  echo
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

write_login_notice(){
  cat >"$LOGIN_NOTICE" <<EOF
#!/usr/bin/env bash
STATE_FILE='$STATE_FILE'
[[ -r "\$STATE_FILE" ]] || exit 0
. "\$STATE_FILE"
[[ "\${MIGRATION_PENDING:-false}" == true ]] || exit 0
now=\$(date +%s)
remaining=\$(( \${ROLLBACK_EPOCH:-0} - now )); ((remaining < 0)) && remaining=0
current_ip=\$(ip -4 route get "\${MGMT_GW:-1.1.1.1}" 2>/dev/null | awk '{for(i=1;i<=NF;i++)if(\$i=="src"){print \$(i+1);exit}}')
printf '\n==============================================================================\nDOMOTZ NETWORK MIGRATION PENDING\n==============================================================================\n\n'
printf 'A network migration is awaiting confirmation.\n\n'
printf 'Interface:       %s\nMAC address:     %s\nOriginal IP:     %s\nCurrent IP:      %s\nRollback at:     %s\nTime remaining:  %02d:%02d\n\n' "\${MGMT_IF:-unknown}" "\${MGMT_MAC:-unknown}" "\${MGMT_IP:-unknown}" "\${current_ip:-unknown}" "\${ROLLBACK_TEXT:-unknown}" \$((remaining/60)) \$((remaining%60))
printf 'Run:\n\n  sudo domotz-pi-provisioner\n\nto review and confirm or roll back the networking update.\n\nDoing nothing will automatically restore the previous network configuration.\n==============================================================================\n\n'
EOF
  chown root:root "$LOGIN_NOTICE"; chmod 0644 "$LOGIN_NOTICE"
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
  chmod 0644 "$STATE_FILE"
  write_login_notice
  cleanup_transient_units
  systemd-run --unit="$ROLLBACK_UNIT" --on-active="${ROLLBACK_SECONDS}s" "$ROLLBACK_SCRIPT" >/dev/null
  pass "Rollback ARMED for $ROLLBACK_SECONDS seconds."; info "Rollback scheduled: $ROLLBACK_TEXT"
}

disarm_rollback(){ cleanup_transient_units; sed -i 's/^MIGRATION_PENDING=.*/MIGRATION_PENDING=false/' "$STATE_FILE"; rm -f "$LOGIN_NOTICE"; MIGRATION_COMMITTED=true; pass 'Rollback canceled; migration COMMITTED.'; }

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
  echo 'If reconnected in another session, run: sudo domotz-pi-provisioner'
  local remaining response
  while true; do
    remaining=$((ROLLBACK_EPOCH-$(date +%s)))
    ((remaining>0)) || { echo; fail 'Confirmation window expired; rollback is running.'; return 1; }
    printf '\rTime remaining: %02d:%02d  Keep changes? [y/N]: ' $((remaining/60)) $((remaining%60))
    if IFS= read -r -t 1 -n 1 response; then case "$response" in y|Y) echo; disarm_rollback; return 0;; n|N|'') echo; rollback_now;; esac; fi
  done
}

run_with_spinner(){
  local label="$1" outfile="$2"; shift 2
  local start pid rc elapsed frame_index=0 frames='|/-\'
  start="$(date +%s)"; "$@" >"$outfile" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$(( $(date +%s) - start ))
    printf '\r%s... %s %02d:%02d' "$label" "${frames:frame_index++%4:1}" $((elapsed/60)) $((elapsed%60))
    sleep 1
  done
  wait "$pid"; rc=$?; elapsed=$(( $(date +%s) - start ))
  printf '\r%-72s\r' ' '; cat "$outfile"
  ((rc==0)) && pass "$label completed in $(printf '%02d:%02d' $((elapsed/60)) $((elapsed%60)))."
  return "$rc"
}

verify_dynavlan_timer(){
  local listing
  systemctl start dynavlan.timer || return 1
  listing="$(systemctl list-timers dynavlan.timer --no-pager 2>/dev/null || true)"
  printf '%s\n' "$listing"
  grep -q 'dynavlan.timer' <<<"$listing" && ! grep -q '^0 timers listed' <<<"$listing"
}

verify_vlan_deployment(){
  local default_if default_gw
  default_if="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="dev"){print $(i+1);exit}}')"
  default_gw="$(ip -4 route show default | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="via"){print $(i+1);exit}}')"
  [[ "$default_if" == "$MGMT_IF" ]] && pass 'Management default-route interface preserved.' || return 1
  [[ "$default_gw" == "$MGMT_GW" ]] && pass 'Management default gateway preserved.' || return 1
  info 'Verifying final VLAN configuration.'
  run_with_spinner 'Verifying VLAN configuration' "$DYNAVLAN_STATUS_LOG" dynavlan --status || { fail 'Final dynavlan status validation failed.'; return 1; }
  grep -q 'configured (owned):' "$DYNAVLAN_STATUS_LOG" || { fail 'Final dynavlan status did not report owned VLAN interfaces.'; return 1; }
  pass 'Final VLAN configuration verified.'
  snap services "$DOMOTZ_SNAP" 2>/dev/null | awk 'NR>1&&$3=="active"{f=1}END{exit !f}' && pass 'Domotz service is active after VLAN deployment.' || warn 'Domotz service is not active after VLAN deployment.'
  verify_dynavlan_timer && pass 'Automatic VLAN rescan timer is scheduled.' || return 1
}

write_dynavlan_activator(){
  cat >"$DYNAVLAN_ACTIVATOR" <<EOF2
#!/usr/bin/env bash
set -u
set -o pipefail
PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
LOG='$LOG_FILE'; OUT='$LOG_DIR/dynavlan-scheduled-dry-run.log'
exec >>"\$LOG" 2>&1
echo "[INFO] Automated dynavlan activation started at \$(date '+%B %-d, %Y at %-I:%M:%S %p %Z')."
dynavlan --dry-run >"\$OUT" 2>&1 || { cat "\$OUT"; exit 1; }
cat "\$OUT"; grep -q 'validate:[[:space:]]*OK' "\$OUT" || exit 1
dynavlan --boot || exit 1
systemctl start dynavlan.timer
systemctl list-timers dynavlan.timer --no-pager
echo '[PASS] Automated dynavlan activation completed.'
systemctl disable domotz-dynavlan-activate.service domotz-dynavlan-activate.timer >/dev/null 2>&1 || true
EOF2
  chmod 0755 "$DYNAVLAN_ACTIVATOR"
  cat >"$DYNAVLAN_ACTIVATION_SERVICE" <<EOF2
[Unit]
Description=Activate dynavlan for Domotz Collector
Wants=network-online.target
After=network-online.target
[Service]
Type=oneshot
ExecStart=$DYNAVLAN_ACTIVATOR
EOF2
  systemctl daemon-reload
}

schedule_next_boot(){
  write_dynavlan_activator
  rm -f "$DYNAVLAN_ACTIVATION_TIMER"; systemctl daemon-reload
  systemctl enable domotz-dynavlan-activate.service >/dev/null
  systemctl disable --now dynavlan.service dynavlan.timer >/dev/null 2>&1 || true
  DYNAVLAN_ACTIVATION='next-boot'; pass 'Automatic VLAN activation armed for the next boot.'
  warn 'The next boot must occur on the network this device will monitor.'
}

schedule_datetime(){
  local d t when
  while true; do
    read -r -p 'Activation date [YYYY-MM-DD]: ' d; read -r -p 'Activation time [HH:MM, 24-hour]: ' t; when="$d $t"
    date -d "$when" >/dev/null 2>&1 && (( $(date -d "$when" +%s) > $(date +%s) )) && break
    warn 'Enter a valid future local date and time.'
  done
  write_dynavlan_activator
  cat >"$DYNAVLAN_ACTIVATION_TIMER" <<EOF2
[Unit]
Description=Scheduled dynavlan activation
[Timer]
OnCalendar=$when
Persistent=true
Unit=domotz-dynavlan-activate.service
[Install]
WantedBy=timers.target
EOF2
  systemctl daemon-reload; systemctl disable dynavlan.service >/dev/null 2>&1 || true; systemctl disable --now dynavlan.timer >/dev/null 2>&1 || true
  systemctl enable --now domotz-dynavlan-activate.timer >/dev/null
  DYNAVLAN_ACTIVATION="scheduled:$when"; pass "VLAN activation scheduled for $(date -d "$when" '+%B %-d, %Y at %-I:%M:%S %p %Z')."
}

leave_disabled(){
  systemctl disable --now dynavlan.service dynavlan.timer domotz-dynavlan-activate.service domotz-dynavlan-activate.timer >/dev/null 2>&1 || true
  DYNAVLAN_ACTIVATION='disabled'; pass 'dynavlan installed; automatic VLAN discovery remains disabled.'
}

staging_options(){
  local choice
  section 'DYNAVLAN STAGING OPTIONS'
  echo 'Choose when automatic VLAN discovery should begin:'
  echo '  1) Next boot - use when the next power-up will occur on the monitored network.'
  echo '  2) Scheduled date and time - use when the device remains powered on.'
  echo '  3) Leave VLAN discovery disabled - use when deployment timing is uncertain.'
  while true; do read -r -p 'Selection [1-3, default 3]: ' choice; case "${choice:-3}" in 1) schedule_next_boot; return;;2) schedule_datetime; return;;3) leave_disabled; return;;*) echo 'Enter 1, 2, or 3.';;esac;done
}

choose_vlan_max(){
  local value
  section 'VLAN DISCOVERY RANGE'
  echo 'dynavlan will scan for tagged VLANs within the configured VLAN ID range.'
  echo
  echo 'Valid VLAN ID range: 1-4094'
  echo 'Default maximum:      1000'
  echo
  echo 'Higher maximum VLAN values may increase discovery time. If you know the'
  echo 'highest VLAN ID used at this site, you can limit discovery to that value.'
  echo
  while true; do
    read -r -p 'Maximum VLAN ID to discover [1-4094, default 1000]: ' value
    value="${value:-1000}"
    if [[ "$value" =~ ^[0-9]+$ ]] && ((value >= 1 && value <= 4094)); then
      VLAN_MAX_SELECTED="$value"
      pass "VLAN discovery range set to 1-$VLAN_MAX_SELECTED."
      break
    fi
    warn 'Enter a whole number from 1 through 4094, or press Enter to use 1000.'
  done
  if grep -qE '^[#[:space:]]*VLAN_MIN=' /etc/dynavlan.conf; then
    sed -Ei 's|^[#[:space:]]*VLAN_MIN=.*|VLAN_MIN=1|' /etc/dynavlan.conf
  else
    printf '
VLAN_MIN=1
' >>/etc/dynavlan.conf
  fi
  if grep -qE '^[#[:space:]]*VLAN_MAX=' /etc/dynavlan.conf; then
    sed -Ei "s|^[#[:space:]]*VLAN_MAX=.*|VLAN_MAX=$VLAN_MAX_SELECTED|" /etc/dynavlan.conf
  else
    printf 'VLAN_MAX=%s
' "$VLAN_MAX_SELECTED" >>/etc/dynavlan.conf
  fi
  info "dynavlan VLAN range configured as 1-$VLAN_MAX_SELECTED."
}

automated_vlan_activation(){
  section 'DYNAVLAN VLAN DISCOVERY'
  info 'Starting dynavlan VLAN discovery. This preview does not modify networking.'
  run_with_spinner 'Discovering tagged VLANs' "$DYNAVLAN_DISCOVERY_LOG" dynavlan --dry-run || return 1
  grep -q 'validate:[[:space:]]*OK' "$DYNAVLAN_DISCOVERY_LOG" || { fail 'dynavlan validation did not report OK.'; return 1; }
  pass 'dynavlan dry-run validation passed.'
  info 'Applying validated VLAN configuration.'
  info 'Verifying detected VLANs before making network changes.'
  run_with_spinner 'Applying VLAN configuration' "$DYNAVLAN_APPLY_LOG" dynavlan --boot || { fail 'dynavlan VLAN apply failed.'; return 1; }
  verify_vlan_deployment || return 1
  DYNAVLAN_ACTIVATION='applied-now'; pass 'VLAN deployment completed.'
}

configure_dynavlan_activation(){
  local answer
  section 'DYNAVLAN VLAN DISCOVERY'
  echo 'dynavlan can scan the connected network for tagged VLANs and preview the'
  echo 'interfaces it would create for Domotz.'; echo
  echo 'This discovery is intended for the network the device will actually monitor.'
  echo 'If this device is being staged on a temporary or test network, skip discovery'
  echo 'now and activate it after installation at the final location.'; echo
  echo 'Is this device currently connected to the network it will be monitoring?'; echo
  echo '  [Y] Yes - discover, validate, and configure VLANs now'
  echo '  [N] No  - the device is currently being staged'; echo
  if [[ "$MODE" == yolo && "$DISCOVER_VLANS" != true ]]; then info 'YOLO defaults to staging-safe disabled VLAN discovery.'; leave_disabled; return; fi
  [[ "$DISCOVER_VLANS" == true ]] && { choose_vlan_max; automated_vlan_activation; return; }
  read -r -p 'Configure VLANs now? [y/N]: ' answer
  if [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; then
    choose_vlan_max
    automated_vlan_activation
  else
    staging_options
  fi
}

install_dynavlan(){
  section 'DYNAVLAN INSTALLATION'
  local installer='/tmp/dynavlan-get.sh' installed_version='' requested_version
  requested_version="${DYNAVLAN_VERSION#v}"
  if command -v dynavlan >/dev/null 2>&1; then
    installed_version="$(dynavlan --version 2>/dev/null | awk 'NR==1{print $2}')"
  fi

  if [[ -n "$installed_version" && "$installed_version" == "$requested_version" ]]; then
    pass "dynavlan v$installed_version is already installed."
    info 'Skipping dynavlan reinstall.'
  else
    if [[ -n "$installed_version" ]]; then info "Upgrading dynavlan from v$installed_version to $DYNAVLAN_VERSION."; else info "Installing dynavlan $DYNAVLAN_VERSION."; fi
    curl -fsSL 'https://raw.githubusercontent.com/pereljon/dynavlan/main/get.sh' -o "$installer" || { fail 'Unable to download dynavlan installer.'; return 1; }
    chmod 0700 "$installer"; bash "$installer" "$DYNAVLAN_VERSION" || { fail 'dynavlan installation or upgrade failed.'; return 1; }
    command -v dynavlan >/dev/null 2>&1 || { fail 'dynavlan command missing after installation.'; return 1; }
    if [[ -n "$installed_version" ]]; then
      info 'Reapplying existing VLAN configuration for the new dynavlan build.'
      dynavlan --reapply || { fail 'dynavlan --reapply failed after upgrade.'; return 1; }
    fi
  fi

  if [[ -f /etc/dynavlan.conf ]]; then
    if grep -q '^#*RESTART_SNAPS=' /etc/dynavlan.conf; then sed -Ei 's|^#*RESTART_SNAPS=.*|RESTART_SNAPS="domotzpro-agent-publicstore"|' /etc/dynavlan.conf; else printf '\nRESTART_SNAPS="domotzpro-agent-publicstore"\n' >>/etc/dynavlan.conf; fi
  else
    fail '/etc/dynavlan.conf is missing.'; return 1
  fi
  dynavlan --version
  DYNAVLAN_INSTALLED=true
  pass 'dynavlan installation and Domotz integration validated.'
  configure_dynavlan_activation
}

section "DOMOTZ PI PROVISIONER $VERSION"
info "Mode: $MODE"; install -o root -g root -m 0755 "$0" "$LAUNCHER"
if systemctl is-active --quiet NetworkManager; then MIGRATION_REQUIRED=true; fi
if [[ "$MIGRATION_REQUIRED" == true ]]; then
  ensure_network_migration_prerequisites || { section 'PROVISIONING STOPPED'; echo 'Required network migration packages could not be installed. No network changes were attempted.'; exit 1; }
  preflight || { section 'PROVISIONING STOPPED'; echo 'Preflight failed. No network migration, full upgrade, or dynavlan changes were attempted.'; exit 1; }
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
printf 'Version:               %s\nMode:                  %s\nManagement interface:  %s\nMAC address:            %s\nOriginal IP:            %s\nPost-migration IP:      %s\nNetwork migrated:       %s\nMigration committed:    %s\nRollback timeout:       %s seconds\nDynavlan installed:     %s\nVLAN activation:        %s\nVLAN discovery range:   1-%s\nErrors:                 %s\nWarnings:               %s\n' "$VERSION" "$MODE" "${MGMT_IF:-unknown}" "${MGMT_MAC:-unknown}" "${MGMT_IP:-unknown}" "${POST_IP:-unchanged/not checked}" "$MIGRATION_REQUIRED" "$MIGRATION_COMMITTED" "$ROLLBACK_SECONDS" "$DYNAVLAN_INSTALLED" "$DYNAVLAN_ACTIVATION" "$VLAN_MAX_SELECTED" "$ERRORS" "$WARNINGS"
pass 'BETA PROVISIONING COMPLETED.'
