#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Simple Wi-Fi AP setup script (hostapd + dnsmasq DHCP only)
# Verified approach based on successful troubleshooting session.
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
    echo "Please run as root: sudo bash $0"
    exit 1
  fi
}

validate_passphrase() {
  local len
  len=${#PASSPHRASE}
  if (( len < 8 || len > 63 )); then
    echo "PASSPHRASE must be between 8 and 63 characters."
    exit 1
  fi
}

install_packages() {
  log "Installing hostapd and dnsmasq..."
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
    log "Moving old zz-ap-debug dnsmasq config out of /etc/dnsmasq.d ..."
    mkdir -p /root/dnsmasq_backup
    mv /etc/dnsmasq.d/zz-ap-debug.conf* /root/dnsmasq_backup/ 2>/dev/null || true
  fi
}

write_hostapd_conf() {
  log "Writing $HOSTAPD_CONF ..."
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
  log "Writing $DNSMASQ_CONF ..."
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
  log "Assigning ${AP_IP}/${AP_CIDR} to ${WIFI_IFACE} ..."
  ip addr flush dev "$WIFI_IFACE" || true
  ip addr add "${AP_IP}/${AP_CIDR}" dev "$WIFI_IFACE"
  ip link set "$WIFI_IFACE" up
}

restart_services() {
  log "Stopping any foreground dnsmasq test instance..."
  pkill -f "dnsmasq --no-daemon" || true

  log "Enabling services..."
  systemctl enable hostapd
  systemctl enable dnsmasq

  log "Restarting hostapd..."
  systemctl restart hostapd

  log "Testing dnsmasq config..."
  dnsmasq --test

  log "Restarting dnsmasq..."
  systemctl restart dnsmasq
}

show_status() {
  echo
  log "==== STATUS ===="
  systemctl --no-pager -l status hostapd || true
  echo
  systemctl --no-pager -l status dnsmasq || true
  echo
  ip addr show "$WIFI_IFACE" || true
  echo
  iw dev || true
  echo
  log "Active leases:"
  cat /var/lib/misc/dnsmasq.leases 2>/dev/null || true
}

print_summary() {
  cat <<EOS

============================================================
Wi-Fi AP setup completed.
============================================================
SSID       : ${SSID}
Password   : ${PASSPHRASE}
Interface  : ${WIFI_IFACE}
AP IP      : ${AP_IP}/${AP_CIDR}
DHCP Range : ${DHCP_START} - ${DHCP_END}

MQTT broker example:
  Host: ${AP_IP}
  Port: 1883   (or 8883 if TLS is configured)

Recommended checks:
  sudo journalctl -fu dnsmasq
  sudo journalctl -fu hostapd
  sudo cat /var/lib/misc/dnsmasq.leases

If iPhone gets 169.254.x.x:
  - verify hostapd is active
  - verify dnsmasq is active
  - verify dhcp-broadcast exists in /etc/dnsmasq.conf
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
