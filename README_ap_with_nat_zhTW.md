# Wi‑Fi AP + NAT 安裝與解除安裝指南（繁體中文）

本文件對應下列腳本：

- `setup_ap_with_nat_v2.sh`：將 Linux 主機設定成 Wi‑Fi AP（`hostapd`）+ DHCP（`dnsmasq`）+ NAT 分享上網
- `uninstall_ap_with_nat.sh`：停止並移除上述設定，盡量恢復原狀

此架構特別適合：

- Linux 小主機當成 iPhone / iPad / Android 的專用 AP
- AP 內網設備要連到本機 MQTT broker（例如 `192.168.50.1:1883`）
- AP 同時要把流量透過有線網卡或其他上游網卡分享出去上網

---

## 一、架構概念

- `hostapd`：負責發出 Wi‑Fi SSID
- `dnsmasq`：只做 DHCP（不做 DNS）
- `iptables`：做 NAT / MASQUERADE
- `sysctl net.ipv4.ip_forward=1`：允許 IPv4 轉送

典型配置：

- Wi‑Fi AP 介面：`wlp0s20f3`
- 上游介面：`enp1s0`
- AP IP：`192.168.50.1/24`
- DHCP 範圍：`192.168.50.100 ~ 192.168.50.200`

---

## 二、為什麼這版設定對 iPhone 特別重要

在本次實測中，iPhone 若連上 AP 後一直轉圈，最後拿到：

- `169.254.x.x`

通常表示 **DHCP 沒有成功完成**。

這次真正解決問題的關鍵設定有三個：

1. `port=0`
   - 讓 `dnsmasq` **只做 DHCP**，不搶 DNS 的 53 port，避免與其他 DNS 服務衝突。

2. `bind-dynamic`
   - 避免 Wi‑Fi AP 介面啟動時序造成 `dnsmasq` 綁定失敗。

3. `dhcp-broadcast`
   - 這是本次 iPhone 一直轉圈、拿不到 DHCP 的關鍵修正。
   - 加上後，iPhone 可正常拿到 `192.168.50.x`，不再退回 `169.254.x.x`。

---

## 三、安裝前準備

請先確認：

1. Linux 系統支援 `hostapd`
2. Wi‑Fi 網卡支援 AP 模式
3. 上游網卡可連外（例如 `enp1s0`）
4. 以 `root` 或 `sudo` 執行腳本

可先確認 Wi‑Fi 是否支援 AP：

```bash
iw dev
```

若看到介面可進入 `type AP`，通常代表可作為基地台。

---

## 四、安裝腳本

### 1. 給腳本執行權限

```bash
chmod +x setup_ap_with_nat_v2.sh
```

### 2. 直接執行

```bash
sudo ./setup_ap_with_nat_v2.sh
```

### 3. 帶參數執行（範例）

```bash
sudo WIFI_IFACE=wlp0s20f3 \
UPLINK_IFACE=enp1s0 \
SSID=0SCORE \
PASSPHRASE='12345678' \
./setup_ap_with_nat_v2.sh
```

---

## 五、腳本會做哪些事

`setup_ap_with_nat_v2.sh` 會：

1. 安裝必要套件：
   - `hostapd`
   - `dnsmasq`
   - `iptables`
   - `iproute2`

2. 寫入以下檔案：
   - `/etc/hostapd/hostapd.conf`
   - `/etc/default/hostapd`
   - `/etc/dnsmasq.conf`
   - `/etc/NetworkManager/conf.d/99-ap-unmanaged.conf`
   - `/usr/local/sbin/ap-static-ip.sh`
   - `/usr/local/sbin/ap-nat-up.sh`
   - `/usr/local/sbin/ap-nat-down.sh`
   - `/etc/systemd/system/ap-static-ip.service`
   - `/etc/systemd/system/ap-nat.service`
   - `/etc/sysctl.d/99-ap-nat.conf`

3. 啟用以下服務：
   - `hostapd`
   - `dnsmasq`
   - `ap-static-ip.service`
   - `ap-nat.service`

4. 將 Wi‑Fi AP 介面設為固定 IP（例如 `192.168.50.1/24`）
5. 開啟 IP forwarding
6. 建立 NAT 規則，讓 AP 客戶端可經由上游介面上網

---

## 六、安裝完成後檢查

### 1. 檢查服務狀態

```bash
sudo systemctl status hostapd dnsmasq ap-static-ip.service ap-nat.service --no-pager -l
```

### 2. 檢查 AP IP

```bash
ip addr show wlp0s20f3
```

應看到類似：

```text
inet 192.168.50.1/24
```

### 3. 檢查 DHCP 租約

```bash
sudo cat /var/lib/misc/dnsmasq.leases
```

### 4. 即時查看 DHCP 記錄

```bash
sudo journalctl -u dnsmasq -f
```

### 5. 檢查 NAT 規則

```bash
sudo iptables -t nat -S
sudo iptables -S
```

### 6. 檢查 IP forwarding

```bash
sysctl net.ipv4.ip_forward
```

應看到：

```text
net.ipv4.ip_forward = 1
```

---

## 七、iPhone 端連線檢查

正常情況下，iPhone 連上 Wi‑Fi AP 後：

- 會看到 Wi‑Fi 名稱旁有勾勾
- 會取得 `192.168.50.x` 的 IP
- Router 應為 `192.168.50.1`

若 iPhone 拿到：

- `169.254.x.x`

代表 DHCP 仍未成功，請先檢查：

- `dnsmasq` 是否 active
- `/etc/dnsmasq.conf` 是否包含 `dhcp-broadcast`
- `sudo journalctl -u dnsmasq -f`

---

## 八、MQTT 使用建議

若 broker 跑在這台 Linux 主機上：

- Broker Host：`192.168.50.1`
- Port：依設定使用 `1883` 或 `8883`

例如 iPhone 連上 `0SCORE` 後，可直接連：

- `192.168.50.1:1883`
- `192.168.50.1:8883`

---

## 九、解除安裝

### 1. 給解除安裝腳本執行權限

```bash
chmod +x uninstall_ap_with_nat.sh
```

### 2. 執行解除安裝

```bash
sudo ./uninstall_ap_with_nat.sh
```

### 3. 若要連安裝套件一起移除

```bash
sudo REMOVE_PACKAGES=yes ./uninstall_ap_with_nat.sh
```

> 預設 **不會移除套件**，只會停止服務、刪除本方案建立的檔案、清除 NAT 規則。

---

## 十、解除安裝腳本會做什麼

`uninstall_ap_with_nat.sh` 會：

- 停止並 disable：
  - `ap-nat.service`
  - `ap-static-ip.service`
  - `hostapd`
  - `dnsmasq`
- 執行 NAT down 腳本（若存在）
- 刪除本方案建立的檔案與 service
- 刪除 `99-ap-nat.conf`
- 將 `net.ipv4.ip_forward` 設回 `0`
- 重新載入 systemd
- 重新啟動 `NetworkManager`（若存在）
- 嘗試從 `/root/ap_setup_backup` 還原先前備份的檔案

---

## 十一、常見問題

### 1. `dnsmasq: failed to create listening socket for 192.168.50.1: Address already in use`

通常代表有另一個 `dnsmasq` 還在跑，尤其是手動測試時用過：

```bash
sudo dnsmasq --no-daemon ...
```

請先關掉手動前景版，再啟動 service 版。

### 2. iPhone 連線一直轉圈，最後拿到 `169.254.x.x`

通常是 DHCP 沒成功。請確認 `dnsmasq.conf` 有：

```ini
port=0
bind-dynamic
dhcp-broadcast
```

### 3. 執行腳本時看到某些 `sysctl ... Invalid argument`

v2 版已將：

```bash
sysctl --system
```

改成：

```bash
sysctl -p /etc/sysctl.d/99-ap-nat.conf
```

可避免讀取系統其他無關的 `sysctl` 設定造成雜訊。

---

## 十二、建議保留的檔案

建議保留以下檔案供日後維護：

- `setup_ap_with_nat_v2.sh`
- `uninstall_ap_with_nat.sh`
- 本 README

---

## 十三、快速指令備忘

### 安裝

```bash
sudo ./setup_ap_with_nat_v2.sh
```

### 解除安裝

```bash
sudo ./uninstall_ap_with_nat.sh
```

### 看服務

```bash
sudo systemctl status hostapd dnsmasq ap-static-ip.service ap-nat.service --no-pager -l
```

### 看 DHCP

```bash
sudo journalctl -u dnsmasq -f
sudo cat /var/lib/misc/dnsmasq.leases
```

### 看 NAT

```bash
sudo iptables -t nat -S
sysctl net.ipv4.ip_forward
```

