#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 簡易 Wi‑Fi AP 建置腳本（hostapd + dnsmasq，只做 DHCP）
# 依據本次實測成功流程整理。
# ============================================================

WIFI_IFACE="${WIFI_IFACE:-wlp0s20f3}"
SSID="${SSID:-0SCORE}"
PASSPHRASE="${PASSPHRASE:-12345678}"
AP_IP="${AP_IP:-192.168.50.1}"
AP_CIDR="${AP_CIDR:-24}"
CHANNEL="${CHANNEL:-6}"
COUNTRY_CODE="${COUNTRY_CODE:-TW}"
DHCP_START="${DHCP_START:-192.168.50.100}"
DHCP_END="${DHCP_END:-192.168.50.200}"

HOSTAPD_CONF="/etc/hostapd/hostapd.conf"
DNSMASQ_CONF="/etc/dnsmasq.conf"

log() {
  echo "[AP-SETUP] $*"
}

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "請用 root 執行，例如：sudo bash $0"
    exit 1
  fi
}

validate_passphrase() {
  local len
  len=${#PASSPHRASE}
  if (( len < 8 || len > 63 )); then
    echo "PASSPHRASE 長度必須介於 8 到 63 個字元之間。"
    exit 1
  fi
}

install_packages() {
  log "安裝 hostapd、dnsmasq、iw ..."
  apt update
  DEBIAN_FRONTEND=noninteractive apt install -y hostapd dnsmasq iw
}

backup_files() {
  local ts
  ts=$(date +%Y%m%d_%H%M%S)

  [[ -f "$HOSTAPD_CONF" ]] && cp "$HOSTAPD_CONF" "${HOSTAPD_CONF}.bak.${ts}"
  [[ -f "$DNSMASQ_CONF" ]] && cp "$DNSMASQ_CONF" "${DNSMASQ_CONF}.bak.${ts}"
  [[ -f /etc/default/hostapd ]] && cp /etc/default/hostapd "/etc/default/hostapd.bak.${ts}"
}

cleanup_old_dnsmasq_debug() {
  if compgen -G "/etc/dnsmasq.d/zz-ap-debug.conf*" > /dev/null; then
    log "把舊的 zz-ap-debug dnsmasq 設定移出 /etc/dnsmasq.d ..."
    mkdir -p /root/dnsmasq_backup
    mv /etc/dnsmasq.d/zz-ap-debug.conf* /root/dnsmasq_backup/ 2>/dev/null || true
  fi
}

write_hostapd_conf() {
  log "寫入 $HOSTAPD_CONF ..."
  cat > "$HOSTAPD_CONF" <<EOC
interface=${WIFI_IFACE}
driver=nl80211
ssid=${SSID}
hw_mode=g
channel=${CHANNEL}
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${PASSPHRASE}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
country_code=${COUNTRY_CODE}
EOC

  if grep -q '^#DAEMON_CONF=' /etc/default/hostapd; then
    sed -i 's|^#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
  elif grep -q '^DAEMON_CONF=' /etc/default/hostapd; then
    sed -i 's|^DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
  else
    echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
  fi
}

write_dnsmasq_conf() {
  log "寫入 $DNSMASQ_CONF ..."
  cat > "$DNSMASQ_CONF" <<EOC
port=0
interface=${WIFI_IFACE}
bind-dynamic
dhcp-range=${DHCP_START},${DHCP_END},255.255.255.0,24h
dhcp-option=3,${AP_IP}
dhcp-option=6,${AP_IP}
dhcp-authoritative
dhcp-broadcast
log-dhcp
EOC
}

configure_interface_ip() {
  log "指定 ${AP_IP}/${AP_CIDR} 到 ${WIFI_IFACE} ..."
  ip addr flush dev "$WIFI_IFACE" || true
  ip addr add "${AP_IP}/${AP_CIDR}" dev "$WIFI_IFACE"
  ip link set "$WIFI_IFACE" up
}

restart_services() {
  log "停止任何前景測試用 dnsmasq ..."
  pkill -f "dnsmasq --no-daemon" || true

  log "啟用服務 ..."
  systemctl enable hostapd
  systemctl enable dnsmasq

  log "重新啟動 hostapd ..."
  systemctl restart hostapd

  log "測試 dnsmasq 設定 ..."
  dnsmasq --test

  log "重新啟動 dnsmasq ..."
  systemctl restart dnsmasq
}

show_status() {
  echo
  log "==== 狀態檢查 ===="
  systemctl --no-pager -l status hostapd || true
  echo
  systemctl --no-pager -l status dnsmasq || true
  echo
  ip addr show "$WIFI_IFACE" || true
  echo
  iw dev || true
  echo
  log "目前租約："
  cat /var/lib/misc/dnsmasq.leases 2>/dev/null || true
}

print_summary() {
  cat <<EOS

============================================================
Wi‑Fi AP 建置完成
============================================================
SSID       : ${SSID}
密碼       : ${PASSPHRASE}
介面       : ${WIFI_IFACE}
AP IP      : ${AP_IP}/${AP_CIDR}
DHCP 範圍  : ${DHCP_START} - ${DHCP_END}

MQTT broker 範例：
  Host: ${AP_IP}
  Port: 1883   （若有 TLS，則可用 8883）

建議檢查指令：
  sudo journalctl -fu dnsmasq
  sudo journalctl -fu hostapd
  sudo cat /var/lib/misc/dnsmasq.leases

若 iPhone 拿到 169.254.x.x：
  - 確認 hostapd 是否 active
  - 確認 dnsmasq 是否 active
  - 確認 /etc/dnsmasq.conf 內有 dhcp-broadcast
============================================================
EOS
}

main() {
  need_root
  validate_passphrase
  install_packages
  backup_files
  cleanup_old_dnsmasq_debug
  write_hostapd_conf
  write_dnsmasq_conf
  configure_interface_ip
  restart_services
  show_status
  print_summary
}

main "$@"
