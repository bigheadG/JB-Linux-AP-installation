# Wi‑Fi AP 安裝指南（hostapd + dnsmasq）

這份文件整理的是本次在 Linux 主機上**實際測通**的 Access Point（AP）建置方式。

## 目標

建立一個名稱為 `0SCORE` 的本地 Wi‑Fi AP，讓 iPhone 可連上此 AP，並存取本機 MQTT broker：`192.168.50.1`。

## 已驗證可行的架構

- `hostapd`：負責建立 Wi‑Fi AP / SSID
- `dnsmasq`：只負責 DHCP
- `wlp0s20f3`：切成 AP 模式的 Wi‑Fi 介面
- AP gateway IP：`192.168.50.1/24`

## 這次排障的關鍵心得

### 1. `hostapd` 正常時，`iw dev` 會顯示 AP 模式
當 `iw dev` 出現下列資訊時，就代表 AP 已經真的建立成功：

- 介面型態：`AP`
- SSID：`0SCORE`

### 2. iPhone 一直轉圈圈，本質上是 DHCP 問題
症狀如下：

- iPhone 可以點到 SSID，但一直轉圈圈
- iPhone 拿到的是 `169.254.x.x`
- `tcpdump` 一直看到 `DHCP Discover`
- 但封包裡看不到 `DHCPOFFER`

### 3. 最關鍵修正是 `dhcp-broadcast`
iPhone 送出的 DHCP 封包是：

- `Flags [none]`

在 `dnsmasq` 啟用：

```ini
dhcp-broadcast
```

之後，iPhone 才順利完成 DHCP，並在 Wi‑Fi 名稱旁顯示勾勾。

### 4. `port=0` 可避免 DNS 53 埠衝突
為了簡化系統並避免 `Address already in use`：

```ini
port=0
```

這表示 `dnsmasq` **只做 DHCP，不做 DNS**，對於本地 AP + MQTT 使用情境已經足夠。

### 5. 不要重複放兩份 dnsmasq AP 設定
請勿同時把 AP 設定放在：

- `/etc/dnsmasq.conf`
- `/etc/dnsmasq.d/*.conf`

建議只保留**一份有效設定來源**。

---

## 套件安裝

```bash
sudo apt update
sudo apt install -y hostapd dnsmasq iw
```

啟用服務：

```bash
sudo systemctl enable hostapd
sudo systemctl enable dnsmasq
```

---

## 步驟 1：為 Wi‑Fi 介面指定 AP IP

先手動指定 AP IP：

```bash
sudo ip addr flush dev wlp0s20f3
sudo ip addr add 192.168.50.1/24 dev wlp0s20f3
sudo ip link set wlp0s20f3 up
```

若要永久保存，可後續再改成：

- systemd unit
- 或 NetworkManager unmanaged / manual 設定

---

## 步驟 2：設定 hostapd

建立 `/etc/hostapd/hostapd.conf`：

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

指定 hostapd 預設設定檔路徑：

```bash
sudo sed -i 's|^#DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
```

重新啟動 hostapd：

```bash
sudo systemctl restart hostapd
sudo systemctl status hostapd --no-pager -l
```

檢查是否為 AP 模式：

```bash
iw dev
```

預期結果：

- 介面：`wlp0s20f3`
- 型態：`AP`
- SSID：`0SCORE`

---

## 步驟 3：設定 dnsmasq

請使用這份已測通的 `/etc/dnsmasq.conf`：

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

說明：

- `port=0`：關閉 DNS 功能，避免 53 埠衝突
- `bind-dynamic`：當開機時介面建立順序較動態時，比較穩定
- `dhcp-broadcast`：本次讓 iPhone DHCP 成功的關鍵

重新啟動前，請先確認 `/etc/dnsmasq.d/` 裡面沒有殘留其他 AP 測試設定。

範例清理指令：

```bash
sudo mv /etc/dnsmasq.d/zz-ap-debug.conf /root/ 2>/dev/null || true
sudo mv /etc/dnsmasq.d/zz-ap-debug.conf.off /root/ 2>/dev/null || true
```

測試並重啟：

```bash
sudo dnsmasq --test
sudo systemctl restart dnsmasq
sudo systemctl status dnsmasq --no-pager -l
```

預期 log：

- `started, version ... DNS disabled`
- `DHCP, IP range 192.168.50.100 -- 192.168.50.200`
- `DHCP, sockets bound exclusively to interface wlp0s20f3`

---

## 步驟 4：iPhone 驗證

在 iPhone 上：

1. 打開 **設定 > Wi‑Fi**
2. 點選 `0SCORE`
3. 若先前失敗過，請先按 **忘記此網路**
4. 再重新連線

預期結果：

- spinning wheel 停止
- `0SCORE` 旁邊出現勾勾
- iPhone 拿到 `192.168.50.x`

如果 iPhone 仍拿到 `169.254.x.x`，就代表 DHCP 仍未成功。

---

## 步驟 5：MQTT Client 設定

當 iPhone 成功連上 AP 後：

- Broker IP：`192.168.50.1`
- 非 TLS port：`1883`
- TLS port：`8883`

範例：

- Host：`192.168.50.1`
- Port：`1883`

---

## 常用除錯指令

### 檢查 hostapd

```bash
sudo systemctl status hostapd
sudo journalctl -u hostapd -b --no-pager | tail -50
iw dev
```

### 檢查 dnsmasq

```bash
sudo systemctl status dnsmasq --no-pager -l
sudo journalctl -u dnsmasq -b --no-pager | tail -50
sudo cat /var/lib/misc/dnsmasq.leases
```

### 即時看 DHCP

```bash
sudo journalctl -fu dnsmasq
```

### 即時抓 DHCP 封包

```bash
sudo tcpdump -ni wlp0s20f3 -vvv -e -n -s0 '(port 67 or port 68 or arp)'
```

---

## 常見問題

### 問題 1：iPhone 一直轉圈圈，拿到 `169.254.x.x`
請檢查：

- `hostapd` 是否 active
- `dnsmasq` 是否 active
- `/etc/dnsmasq.conf` 是否有 `dhcp-broadcast`
- 是否還殘留重複的 dnsmasq 設定檔

### 問題 2：`dnsmasq` 啟動失敗，出現 `Address already in use`
通常代表：

- 還有另一個 `dnsmasq` 在跑
- 或 53 port 被其他 DNS 服務佔用

本次建議做法是：

```ini
port=0
```

讓 `dnsmasq` 只做 DHCP。

### 問題 3：手動前景測試 `dnsmasq --no-daemon` 後，正式 service 起不來
這通常是因為前景版 `dnsmasq` 還沒有關掉。

可用以下指令清掉：

```bash
sudo pkill -f "dnsmasq --no-daemon"
```

---

## 建議後續延伸

若之後要讓 iPhone 連上 AP 後還能同時上外網，可再加：

- IP forwarding
- NAT / masquerade
- 對外網卡（如 `enp1s0`）做共享

目前這份配置已適合：

- 本地 AP
- 本地 MQTT broker 連線
- iPhone / Scoreboard 裝置區域網互連
