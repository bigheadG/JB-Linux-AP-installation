#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------------------------------
# setup_ap_with_nat_v2.sh
#
# 用途：
#   將 Linux 主機設定成 Wi‑Fi AP（hostapd + dnsmasq）並開啟 NAT，
#   讓 iPhone / 其他裝置連上 AP 後，可以透過上游網路介面上網。
#
# v2 修正重點：
#   1) 不再使用 sysctl --system，改成只載入本腳本建立的 sysctl 檔
#      避免出現與本腳本無關的 sysctl 雜訊，例如：
#      - net.ipv4.conf.all.accept_source_route: Invalid argument
#      - net.ipv4.conf.all.promote_secondaries: Invalid argument
#   2) 保留本次已驗證成功的關鍵設定：
#      - dnsmasq 使用 port=0（只做 DHCP，不搶 DNS 53 port）
#      - bind-dynamic（避免 AP 介面啟動時序問題）
#      - dhcp-broadcast（修正 iPhone 一直轉圈 / 169.254.x.x 問題）
#   3) 啟動後增加基本檢查與摘要輸出。
# ------------------------------------------------------------

VERSION="2.0"

# ===== 可用環境變數覆蓋的預設值 =====
WIFI_IFACE="${WIFI_IFACE:-wlp0s20f3}"
UPLINK_IFACE="${UPLINK_IFACE:-$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')}"
UPLINK_IFACE="${UPLINK_IFACE:-enp1s0}"
SSID="${SSID:-0SCORE}"
PASSPHRASE="${PASSPHRASE:-12345678}"
COUNTRY="${COUNTRY:-TW}"
CHANNEL="${CHANNEL:-6}"
HW_MODE="${HW_MODE:-g}"
AP_IP="${AP_IP:-192.168.50.1}"
AP_CIDR="${AP_CIDR:-24}"
DHCP_START="${DHCP_START:-192.168.50.100}"
DHCP_END="${DHCP_END:-192.168.50.200}"
LEASE_TIME="${LEASE_TIME:-24h}"
DNS_SERVERS="${DNS_SERVERS:-8.8.8.8,1.1.1.1}"
NM_UNMANAGED="${NM_UNMANAGED:-yes}"

HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
DNSMASQ_CONF="/etc/dnsmasq.conf"
NM_UNMANAGED_CONF="/etc/NetworkManager/conf.d/99-ap-unmanaged.conf"
STATIC_IP_SCRIPT="/usr/local/sbin/ap-static-ip.sh"
NAT_UP_SCRIPT="/usr/local/sbin/ap-nat-up.sh"
NAT_DOWN_SCRIPT="/usr/local/sbin/ap-nat-down.sh"
STATIC_IP_SERVICE="/etc/systemd/system/ap-static-ip.service"
NAT_SERVICE="/etc/systemd/system/ap-nat.service"
SYSCTL_CONF="/etc/sysctl.d/99-ap-nat.conf"
BACKUP_DIR="/root/ap_setup_backup"

log() {
  echo "[$(date '+%F %T')] $*"
}

fail() {
  echo "[ERROR] $*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || fail "請使用 sudo 或 root 執行此腳本。"
}

validate_inputs() {
  if [[ ${#PASSPHRASE} -lt 8 || ${#PASSPHRASE} -gt 63 ]]; then
    fail "PASSPHRASE 長度必須在 8 到 63 字元之間。"
  fi

  if [[ "$WIFI_IFACE" == "$UPLINK_IFACE" ]]; then
    fail "WIFI_IFACE 與 UPLINK_IFACE 不能是同一張網卡。"
  fi

  command -v python3 >/dev/null 2>&1 || fail "需要 python3 來計算 AP 子網路。"
  ip link show "$WIFI_IFACE" >/dev/null 2>&1 || fail "找不到 Wi‑Fi 介面：$WIFI_IFACE"
  ip link show "$UPLINK_IFACE" >/dev/null 2>&1 || fail "找不到上游介面：$UPLINK_IFACE"
}

backup_file_if_exists() {
  local file="$1"
  if [[ -f "$file" ]]; then
    mkdir -p "$BACKUP_DIR"
    cp -a "$file" "$BACKUP_DIR/$(basename "$file").bak.$(date +%Y%m%d_%H%M%S)"
  fi
}

install_packages() {
  local missing=()
  command -v hostapd >/dev/null 2>&1 || missing+=(hostapd)
  command -v dnsmasq >/dev/null 2>&1 || missing+=(dnsmasq)
  command -v iptables >/dev/null 2>&1 || missing+=(iptables)
  command -v ip >/dev/null 2>&1 || missing+=(iproute2)

  if (( ${#missing[@]} > 0 )); then
    log "安裝缺少的套件：${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y "${missing[@]}"
  else
    log "必要套件已存在，略過安裝。"
  fi
}

calc_ap_network() {
  AP_NETWORK_CIDR="$({ python3 - "$AP_IP" "$AP_CIDR" <<'PY'
import ipaddress, sys
iface = ipaddress.ip_interface(f"{sys.argv[1]}/{sys.argv[2]}")
print(str(iface.network))
PY
  } )"
}

write_hostapd_conf() {
  log "寫入 ${HOSTAPD_CONF}"
  backup_file_if_exists "$HOSTAPD_CONF"
  cat > "$HOSTAPD_CONF" <<EOF_HOSTAPD
interface=${WIFI_IFACE}
driver=nl80211
ssid=${SSID}
hw_mode=${HW_MODE}
channel=${CHANNEL}
country_code=${COUNTRY}
ieee80211d=1
ieee80211n=1
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${PASSPHRASE}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF_HOSTAPD

  backup_file_if_exists /etc/default/hostapd
  cat > /etc/default/hostapd <<EOF_DEFAULT_HOSTAPD
DAEMON_CONF="${HOSTAPD_CONF}"
EOF_DEFAULT_HOSTAPD
}

write_dnsmasq_conf() {
  log "寫入 ${DNSMASQ_CONF}"
  backup_file_if_exists "$DNSMASQ_CONF"
  cat > "$DNSMASQ_CONF" <<EOF_DNSMASQ
port=0
interface=${WIFI_IFACE}
bind-dynamic
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,${LEASE_TIME}
dhcp-option=3,${AP_IP}
dhcp-option=6,${DNS_SERVERS}
dhcp-authoritative
dhcp-broadcast
log-dhcp
EOF_DNSMASQ

  # 避免之前測試檔造成重複設定
  mkdir -p "$BACKUP_DIR"
  shopt -s nullglob
  for f in /etc/dnsmasq.d/zz-ap-debug.conf*; do
    mv "$f" "$BACKUP_DIR/"
  done
  shopt -u nullglob
}

write_nm_unmanaged_conf() {
  if [[ "$NM_UNMANAGED" != "yes" ]]; then
    log "略過 NetworkManager unmanaged 設定。"
    return
  fi

  if ! command -v nmcli >/dev/null 2>&1; then
    log "找不到 nmcli，略過 NetworkManager unmanaged 設定。"
    return
  fi

  log "設定 NetworkManager 不管理 ${WIFI_IFACE}"
  mkdir -p /etc/NetworkManager/conf.d
  backup_file_if_exists "$NM_UNMANAGED_CONF"
  cat > "$NM_UNMANAGED_CONF" <<EOF_NM
[keyfile]
unmanaged-devices=interface-name:${WIFI_IFACE}
EOF_NM
}

write_static_ip_script_and_service() {
  log "建立 AP 固定 IP 腳本與 systemd service"
  cat > "$STATIC_IP_SCRIPT" <<EOF_STATIC_IP
#!/usr/bin/env bash
set -e
ip link set ${WIFI_IFACE} up
ip addr replace ${AP_IP}/${AP_CIDR} dev ${WIFI_IFACE}
EOF_STATIC_IP
  chmod +x "$STATIC_IP_SCRIPT"

  cat > "$STATIC_IP_SERVICE" <<EOF_STATIC_IP_SERVICE
[Unit]
Description=Assign static IP to Wi-Fi AP interface
After=NetworkManager.service network.target
Before=hostapd.service dnsmasq.service
Wants=NetworkManager.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${STATIC_IP_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF_STATIC_IP_SERVICE
}

write_nat_scripts_and_service() {
  log "建立 NAT 腳本與 systemd service"

  cat > "$NAT_UP_SCRIPT" <<EOF_NAT_UP
#!/usr/bin/env bash
set -e
sysctl -w net.ipv4.ip_forward=1 >/dev/null

iptables -C FORWARD -i ${UPLINK_IFACE} -o ${WIFI_IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -i ${UPLINK_IFACE} -o ${WIFI_IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

iptables -C FORWARD -i ${WIFI_IFACE} -o ${UPLINK_IFACE} -j ACCEPT 2>/dev/null || \
iptables -A FORWARD -i ${WIFI_IFACE} -o ${UPLINK_IFACE} -j ACCEPT

iptables -t nat -C POSTROUTING -s ${AP_NETWORK_CIDR} -o ${UPLINK_IFACE} -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s ${AP_NETWORK_CIDR} -o ${UPLINK_IFACE} -j MASQUERADE
EOF_NAT_UP
  chmod +x "$NAT_UP_SCRIPT"

  cat > "$NAT_DOWN_SCRIPT" <<EOF_NAT_DOWN
#!/usr/bin/env bash
set +e
iptables -D FORWARD -i ${UPLINK_IFACE} -o ${WIFI_IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null
iptables -D FORWARD -i ${WIFI_IFACE} -o ${UPLINK_IFACE} -j ACCEPT 2>/dev/null
iptables -t nat -D POSTROUTING -s ${AP_NETWORK_CIDR} -o ${UPLINK_IFACE} -j MASQUERADE 2>/dev/null
EOF_NAT_DOWN
  chmod +x "$NAT_DOWN_SCRIPT"

  cat > "$NAT_SERVICE" <<EOF_NAT_SERVICE
[Unit]
Description=Enable NAT for Wi-Fi AP
After=network-online.target ap-static-ip.service hostapd.service dnsmasq.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${NAT_UP_SCRIPT}
ExecStop=${NAT_DOWN_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF_NAT_SERVICE

  cat > "$SYSCTL_CONF" <<EOF_SYSCTL
net.ipv4.ip_forward=1
EOF_SYSCTL
}

apply_runtime_config() {
  log "套用執行中設定"
  systemctl daemon-reload

  # 停止服務以避免舊設定干擾
  systemctl stop hostapd 2>/dev/null || true
  systemctl stop dnsmasq 2>/dev/null || true
  pkill -f "dnsmasq --no-daemon" 2>/dev/null || true

  if [[ "$NM_UNMANAGED" == "yes" ]] && systemctl is-active NetworkManager >/dev/null 2>&1; then
    systemctl restart NetworkManager
    sleep 2
  fi

  "$STATIC_IP_SCRIPT"

  # v2 修正：只載入本腳本建立的 sysctl 檔，避免 sysctl --system 的雜訊
  sysctl -p "$SYSCTL_CONF" >/dev/null

  dnsmasq --test >/dev/null

  systemctl enable ap-static-ip.service >/dev/null
  systemctl enable hostapd >/dev/null
  systemctl enable dnsmasq >/dev/null
  systemctl enable ap-nat.service >/dev/null

  systemctl restart ap-static-ip.service
  systemctl restart hostapd
  systemctl restart dnsmasq
  systemctl restart ap-nat.service
}

post_checks() {
  log "進行啟動後檢查"

  systemctl is-active --quiet hostapd || fail "hostapd 未成功啟動。請檢查：sudo systemctl status hostapd --no-pager -l"
  systemctl is-active --quiet dnsmasq || fail "dnsmasq 未成功啟動。請檢查：sudo systemctl status dnsmasq --no-pager -l"
  systemctl is-active --quiet ap-nat.service || fail "ap-nat.service 未成功啟動。請檢查：sudo systemctl status ap-nat.service --no-pager -l"

  local ipfwd
  ipfwd="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
  [[ "$ipfwd" == "1" ]] || fail "net.ipv4.ip_forward 不是 1，NAT 可能無法運作。"
}

show_summary() {
  log "=== 完成（v${VERSION}） ==="
  echo
  echo "AP 設定："
  echo "  SSID         : ${SSID}"
  echo "  Wi‑Fi 介面   : ${WIFI_IFACE}"
  echo "  上游介面     : ${UPLINK_IFACE}"
  echo "  AP IP        : ${AP_IP}/${AP_CIDR}"
  echo "  DHCP 範圍    : ${DHCP_START} ~ ${DHCP_END}"
  echo "  用戶端 DNS   : ${DNS_SERVERS}"
  echo
  echo "客戶端連上 ${SSID} 後："
  echo "  - 應取得 ${DHCP_START} ~ ${DHCP_END} 的 IP"
  echo "  - Gateway 應為 ${AP_IP}"
  echo "  - 可經由 ${UPLINK_IFACE} NAT 上網"
  echo
  echo "MQTT 建議："
  echo "  - Broker Host 可填 ${AP_IP}"
  echo "  - Port 依你的 broker 設定使用 1883 或 8883"
  echo
  echo "快速檢查指令："
  echo "  sudo systemctl status hostapd dnsmasq ap-static-ip.service ap-nat.service --no-pager -l"
  echo "  ip addr show ${WIFI_IFACE}"
  echo "  sudo journalctl -u dnsmasq -f"
  echo "  sudo iptables -t nat -S"
  echo "  sysctl net.ipv4.ip_forward"
}

main() {
  require_root
  validate_inputs
  calc_ap_network

  log "開始設定 Wi‑Fi AP + NAT（v${VERSION}）"
  log "WIFI_IFACE=${WIFI_IFACE}, UPLINK_IFACE=${UPLINK_IFACE}, AP_NETWORK=${AP_NETWORK_CIDR}"

  install_packages
  write_hostapd_conf
  write_dnsmasq_conf
  write_nm_unmanaged_conf
  write_static_ip_script_and_service
  write_nat_scripts_and_service
  apply_runtime_config
  post_checks
  show_summary
}

main "$@"
