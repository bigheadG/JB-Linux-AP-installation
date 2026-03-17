# Wi-Fi AP Installation Guide (hostapd + dnsmasq)

This guide documents the working Access Point (AP) setup that was verified on the Linux box.

## Goal

Create a local Wi-Fi AP named `0SCORE` so iPhone clients can connect and reach the local MQTT broker at `192.168.50.1`.

## Working Architecture

- `hostapd`: provides the Wi-Fi AP / SSID
- `dnsmasq`: provides DHCP only
- `wlp0s20f3`: Wi-Fi interface in AP mode
- AP gateway IP: `192.168.50.1/24`

## Important Lessons Learned

### 1. `hostapd` was working
The AP was correctly created when `iw dev` showed:

- interface type: `AP`
- SSID: `0SCORE`

### 2. The iPhone spinning wheel problem was DHCP-related
Symptoms:

- iPhone connected to SSID but kept spinning
- iPhone got `169.254.x.x`
- tcpdump showed repeated `DHCP Discover`
- no `DHCPOFFER` seen on the wire

### 3. The key fix was `dhcp-broadcast`
The DHCP client sent packets with `Flags [none]`, and after enabling:

```ini
 dhcp-broadcast
```

iPhone successfully completed DHCP and showed a check mark.

### 4. `port=0` avoids DNS conflicts
To keep the setup simple and avoid `Address already in use` on port 53:

```ini
port=0
```

This makes `dnsmasq` serve **DHCP only**, which is enough for local AP + MQTT use.

### 5. Avoid duplicate dnsmasq config
Do **not** keep duplicate AP settings in both:

- `/etc/dnsmasq.conf`
- `/etc/dnsmasq.d/*.conf`

Use a single active config source only.

---

## Package Installation

```bash
sudo apt update
sudo apt install -y hostapd dnsmasq
```

Enable services:

```bash
sudo systemctl enable hostapd
sudo systemctl enable dnsmasq
```

---

## Step 1: Assign AP IP to Wi-Fi Interface

Assign the AP IP manually:

```bash
sudo ip addr flush dev wlp0s20f3
sudo ip addr add 192.168.50.1/24 dev wlp0s20f3
sudo ip link set wlp0s20f3 up
```

To persist it, you can later implement a systemd unit or NetworkManager unmanaged/manual config.

---

## Step 2: Configure hostapd

Create `/etc/hostapd/hostapd.conf`:

```ini
interface=wlp0s20f3
driver=nl80211
ssid=0SCORE
hw_mode=g
channel=6
wmm_enabled=1
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=12345678
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
country_code=TW
```

Set default hostapd config path:

```bash
sudo sed -i 's|^#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
```

Restart hostapd:

```bash
sudo systemctl restart hostapd
sudo systemctl status hostapd --no-pager -l
```

Check AP mode:

```bash
iw dev
```

Expected:

- interface `wlp0s20f3`
- type `AP`
- ssid `0SCORE`

---

## Step 3: Configure dnsmasq

Use this working `/etc/dnsmasq.conf`:

```ini
port=0
interface=wlp0s20f3
bind-dynamic
dhcp-range=192.168.50.100,192.168.50.200,255.255.255.0,24h
dhcp-option=3,192.168.50.1
dhcp-option=6,192.168.50.1
dhcp-authoritative
dhcp-broadcast
log-dhcp
```

Notes:

- `port=0` disables DNS service to avoid port 53 conflicts
- `bind-dynamic` helps when interface timing is dynamic during boot
- `dhcp-broadcast` was the critical fix for iPhone DHCP success

Before restarting, ensure there is no extra AP config left in `/etc/dnsmasq.d/`.

Example cleanup:

```bash
sudo mv /etc/dnsmasq.d/zz-ap-debug.conf /root/ 2>/dev/null || true
sudo mv /etc/dnsmasq.d/zz-ap-debug.conf.off /root/ 2>/dev/null || true
```

Test and restart:

```bash
sudo dnsmasq --test
sudo systemctl restart dnsmasq
sudo systemctl status dnsmasq --no-pager -l
```

Expected log lines:

- `started, version ... DNS disabled`
- `DHCP, IP range 192.168.50.100 -- 192.168.50.200`
- `DHCP, sockets bound exclusively to interface wlp0s20f3`

---

## Step 4: iPhone Verification

On iPhone:

1. Open **Settings > Wi-Fi**
2. Select `0SCORE`
3. If previously failed, use **Forget This Network** first
4. Reconnect

Expected:

- spinning wheel stops
- check mark appears
- iPhone gets an IP in `192.168.50.x`

If iPhone gets `169.254.x.x`, DHCP is still failing.

---

## Step 5: MQTT Client Settings

Once connected to AP:

- Broker IP: `192.168.50.1`
- Non-TLS port: `1883`
- TLS port: `8883`

Example:

- Host: `192.168.50.1`
- Port: `1883`

---

## Useful Debug Commands

### Check hostapd

```bash
sudo systemctl status hostapd
sudo journalctl -u hostapd -b --no-pager | tail -50
iw dev
```

### Check dnsmasq

```bash
sudo systemctl status dnsmasq --no-pager -l
sudo journalctl -u dnsmasq -b --no-pager | tail -50
sudo cat /var/lib/misc/dnsmasq.leases
```

### Watch DHCP live

```bash
sudo journalctl -fu dnsmasq
```

### Packet capture DHCP/ARP

```bash
sudo tcpdump -ni wlp0s20f3 -vvv -e -n -s0 '(port 67 or port 68 or arp)'
```

---

## Common Problems and Fixes

### Problem: `dnsmasq: failed to create listening socket ... Address already in use`
Cause:

- another dnsmasq already running
- a manually started foreground `dnsmasq --no-daemon` still active
- DNS port 53 conflict

Fix:

```bash
sudo pkill -f "dnsmasq --no-daemon"
```

And keep:

```ini
port=0
```

---

### Problem: iPhone keeps spinning and gets `169.254.x.x`
Cause:

- DHCP not completing

Fix:

- verify `dnsmasq` is active
- verify `dhcp-broadcast` is present
- verify `tcpdump` shows `DHCPOFFER`

---

### Problem: `warning: interface wlp0s20f3 does not currently exist`
Cause:

- interface timing during boot

Fix:

- use `bind-dynamic`
- start `hostapd` before `dnsmasq`

---

## Optional Improvement

If you later want iPhone clients on the AP to access the internet through Ethernet, add:

- IP forwarding
- NAT / masquerade

That is not required for local MQTT-only use.

---

## Final Working Summary

The following combination was confirmed working:

- `hostapd` provides SSID `0SCORE`
- `dnsmasq` provides DHCP only
- Wi-Fi interface: `wlp0s20f3`
- AP IP: `192.168.50.1/24`
- Critical DHCP fix: `dhcp-broadcast`
- Conflict prevention: `port=0`

