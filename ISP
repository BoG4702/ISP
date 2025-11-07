#!/usr/bin/env bash
set -euo pipefail

# === Проверки окружения ===
if [[ $EUID -ne 0 ]]; then
  echo "Запусти скрипт от root." >&2
  exit 1
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "Нужна утилита: $1"; exit 1; }; }

need ip
need sysctl
TZ_NAME="Asia/Novosibirsk"
a
echo "=== Настройка ISP на ALT JeOS ==="

# --- Сбор параметров ---
read -rp "Имя устройства (hostname) [isp-alt]: " NEW_HOSTNAME
NEW_HOSTNAME=${NEW_HOSTNAME:-isp-alt}

# Имена интерфейсов (как в ip link): WAN в Интернет; HQ к HQ-RTR; BR к BR-RTR
ip -o link show | awk -F': ' '{print $2}' | nl -w2 -s'. ' | sed 's/^/  /'
read -rp "Имя интерфейса WAN (DHCP) [eth0]: " IF_WAN
read -rp "Имя интерфейса к HQ-RTR (static) [eth1]: " IF_HQ
read -rp "Имя интерфейса к BR-RTR (static) [eth2]: " IF_BR
IF_WAN=${IF_WAN:-eth0}
IF_HQ=${IF_HQ:-eth1}
IF_BR=${IF_BR:-eth2}

# Подсети (из задания): 172.16.4.0/28 и 172.16.5.0/28 (можно заменить)
read -rp "Подсеть HQ (CIDR) [172.16.4.0/28]: " HQ_NET
read -rp "IP/маска для интерфейса HQ (например .1/28) [172.16.4.1/28]: " HQ_IP
read -rp "Подсеть BR (CIDR) [172.16.5.0/28]: " BR_NET
read -rp "IP/маска для интерфейса BR [172.16.5.1/28]: " BR_IP
HQ_NET=${HQ_NET:-172.16.4.0/28}
HQ_IP=${HQ_IP:-172.16.4.1/28}
BR_NET=${BR_NET:-172.16.5.0/28}
BR_IP=${BR_IP:-172.16.5.1/28}

# SNAT IP: если указать внешний IP — будет SNAT; если пусто — MASQUERADE
read -rp "Фиксированный внешний IP для SNAT (пусто = MASQUERADE): " SNAT_IP || true
SNAT_MODE="masq"
[[ -n "${SNAT_IP:-}" ]] && SNAT_MODE="snat"

echo
echo "Итого:"
echo "  Hostname:         $NEW_HOSTNAME"
echo "  Timezone:         $TZ_NAME"
echo "  WAN (DHCP):       $IF_WAN"
echo "  HQ:               $IF_HQ  -> $HQ_IP  (сеть $HQ_NET)"
echo "  BR:               $IF_BR  -> $BR_IP  (сеть $BR_NET)"
if [[ "$SNAT_MODE" == "snat" ]]; then
  echo "  NAT:              SNAT to $SNAT_IP"
else
  echo "  NAT:              MASQUERADE"
fi
echo

read -rp "Продолжить? [y/N]: " go
[[ "${go,,}" == "y" ]] || exit 0

# --- Hostname и часовой пояс ---
echo ">> Устанавливаю hostname и часовой пояс..."
hostnamectl set-hostname "$NEW_HOSTNAME"
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-timezone "$TZ_NAME"
else
  ln -sf "/usr/share/zoneinfo/$TZ_NAME" /etc/localtime
fi

# --- Включаем IPv4 forwarding (и делаем постоянным) ---
echo ">> Включаю IPv4 forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
mkdir -p /etc/sysctl.d
cat >/etc/sysctl.d/99-router.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF

# --- Поднимаем интерфейсы и адреса ---
echo ">> Настраиваю интерфейсы..."
ip link set "$IF_HQ" up
ip addr flush dev "$IF_HQ" || true
ip addr add "$HQ_IP" dev "$IF_HQ"

ip link set "$IF_BR" up
ip addr flush dev "$IF_BR" || true
ip addr add "$BR_IP" dev "$IF_BR"

ip link set "$IF_WAN" up

# WAN по DHCP
if command -v nmcli >/dev/null 2>&1; then
  # Предпочтительно через NetworkManager, если установлен
  echo ">> WAN через NetworkManager (DHCP)..."
  nmcli -t -f NAME,DEVICE con show | grep -q ":$IF_WAN$" || nmcli con add type ethernet ifname "$IF_WAN" con-name "wan-$IF_WAN" ipv4.method auto ipv6.method ignore
  nmcli con up "wan-$IF_WAN" || nmcli dev reapply "$IF_WAN" || true
elif command -v dhclient >/dev/null 2>&1; then
  echo ">> WAN через dhclient (DHCP)..."
  dhclient -r "$IF_WAN" || true
  dhclient "$IF_WAN" || true
else
  echo "Внимание: ни nmcli, ни dhclient не найдены. WAN адрес не выдан автоматически." >&2
fi

# --- NAT: nftables (предпочтительно) или iptables ---
echo ">> Настраиваю NAT..."
if command -v nft >/dev/null 2>&1; then
  cat >/etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet nat {
  chain prerouting { type nat hook prerouting priority -100; }
  chain postrouting {
    type nat hook postrouting priority 100;
    policy accept;
    # NAT для HQ и BR
    $( [[ "$SNAT_MODE" == "snat" ]] && echo "ip saddr $HQ_NET oifname \"$IF_WAN\" snat to $SNAT_IP" || echo "ip saddr $HQ_NET oifname \"$IF_WAN\" masquerade" )
    $( [[ "$SNAT_MODE" == "snat" ]] && echo "ip saddr $BR_NET oifname \"$IF_WAN\" snat to $SNAT_IP" || echo "ip saddr $BR_NET oifname \"$IF_WAN\" masquerade" )
  }
}
EOF
  systemctl enable --now nftables >/dev/null 2>&1 || true
  nft -f /etc/nftables.conf
  echo "NAT настроен через nftables и сохранён в /etc/nftables.conf"
else
  need iptables
  # Правила в runtime
  iptables -t nat -C POSTROUTING -s "$HQ_NET" -o "$IF_WAN" -j MASQUERADE 2>/dev/null && iptables -t nat -D POSTROUTING -s "$HQ_NET" -o "$IF_WAN" -j MASQUERADE || true
  iptables -t nat -C POSTROUTING -s "$BR_NET" -o "$IF_WAN" -j MASQUERADE 2>/dev/null && iptables -t nat -D POSTROUTING -s "$BR_NET" -o "$IF_WAN" -j MASQUERADE || true

  if [[ "$SNAT_MODE" == "snat" ]]; then
    iptables -t nat -A POSTROUTING -s "$HQ_NET" -o "$IF_WAN" -j SNAT --to-source "$SNAT_IP"
    iptables -t nat -A POSTROUTING -s "$BR_NET" -o "$IF_WAN" -j SNAT --to-source "$SNAT_IP"
  else
    iptables -t nat -A POSTROUTING -s "$HQ_NET" -o "$IF_WAN" -j MASQUERADE
    iptables -t nat -A POSTROUTING -s "$BR_NET" -o "$IF_WAN" -j MASQUERADE
  fi

  # Сохранение iptables (универсально)
  mkdir -p /etc/iptables
  iptables-save > /etc/iptables/rules.v4

  # Юнит для восстановления при старте
  cat >/etc/systemd/system/iptables-restore.service <<'UNIT'
[Unit]
Description=Restore iptables rules
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables/rules.v4
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now iptables-restore.service
  echo "NAT настроен через iptables и будет восстанавливаться при старте."
fi

echo "Готово."
