#!/bin/bash
# M1: Настройка маршрутизатора ISP (Alt Linux JeOS)
# - Настраивает сетевые интерфейсы ens19/ens20/ens21
# - Включает доступ в Интернет и NAT для двух внутренних сетей
# - Выставляет часовой пояс Asia/Novosibirsk
# Использование:
#   chmod +x m1_isp.sh
#   sudo ./m1_isp.sh
#   # Для дебага:
#   sudo bash -x ./m1_isp.sh

set -euo pipefail

### ===== ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ =====

log() {
    echo ""
    echo "========== $* =========="
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Ошибка: скрипт нужно запускать от root (sudo или под учеткой root)." >&2
        exit 1
    fi
}

ask_with_default() {
    # $1 - имя переменной, $2 - текст вопроса, $3 - значение по умолчанию
    local __var_name="$1"
    local __prompt="$2"
    local __default="$3"
    local __answer

    read -rp "$__prompt [$__default]: " __answer
    if [[ -z "$__answer" ]]; then
        __answer="$__default"
    fi
    printf -v "$__var_name" '%s' "$__answer"
}

### ===== ПРОВЕРКИ =====

require_root

log "1. Установка часового пояса Asia/Novosibirsk"
timedatectl set-timezone Asia/Novosibirsk || echo "Предупреждение: не удалось установить таймзону (проверь timedatectl)."

### ===== НАСТРОЙКА uplink-интерфейса ENS19 (к провайдеру) =====

log "2. Настройка uplink-интерфейса ens19 (магистральный провайдер)"

mkdir -p /etc/net/ifaces/ens19

read -rp "Использовать DHCP для интерфейса ens19 (магистральный провайдер)? [Y/n]: " USE_DHCP
USE_DHCP=${USE_DHCP:-Y}

if [[ "$USE_DHCP" =~ ^[Yy]$ ]]; then
    log "2.1. Включаем BOOTPROTO=dhcp для ens19"

    cat > /etc/net/ifaces/ens19/options <<EOF
TYPE=eth
BOOTPROTO=dhcp
EOF

    rm -f /etc/net/ifaces/ens19/ipv4address \
          /etc/net/ifaces/ens19/ipv4route \
          /etc/net/ifaces/ens19/resolv.conf

else
    log "2.1. Настройка ens19 со статическим IP"

    ask_with_default ISP_EXT_IP  "IP-адрес/маска для ens19 (например, 192.168.100.2/27)" "192.168.100.2/27"
    ask_with_default ISP_EXT_GW  "Шлюз по умолчанию провайдера"                            "192.168.100.1"
    ask_with_default ISP_EXT_DNS "DNS-сервер (для выхода в Интернет)"                      "77.88.8.8"

    cat > /etc/net/ifaces/ens19/options <<EOF
TYPE=eth
BOOTPROTO=static
EOF

    echo "$ISP_EXT_IP" > /etc/net/ifaces/ens19/ipv4address
    echo "default via $ISP_EXT_GW" > /etc/net/ifaces/ens19/ipv4route
    echo "nameserver $ISP_EXT_DNS" > /etc/net/ifaces/ens19/resolv.conf
fi

### ===== НАСТРОЙКА ВНУТРЕННИХ ИНТЕРФЕЙСОВ ENS20 / ENS21 =====

log "3. Настройка внутренних интерфейсов ens20 (к HQ-RTR) и ens21 (к BR-RTR)"

mkdir -p /etc/net/ifaces/ens20
mkdir -p /etc/net/ifaces/ens21

cat > /etc/net/ifaces/ens20/options <<EOF
TYPE=eth
BOOTPROTO=static
EOF
cp /etc/net/ifaces/ens20/options /etc/net/ifaces/ens21/options

# Спрашиваем IP/маску для линков к HQ-RTR и BR-RTR
ask_with_default ISP_HQ_NET_IP "IP/маска для ens20 (в сторону HQ-RTR)" "172.16.1.1/28"
ask_with_default ISP_BR_NET_IP "IP/маска для ens21 (в сторону BR-RTR)" "172.16.2.1/28"

echo "$ISP_HQ_NET_IP" > /etc/net/ifaces/ens20/ipv4address
echo "$ISP_BR_NET_IP" > /etc/net/ifaces/ens21/ipv4address

### ===== ПРИМЕНЕНИЕ СЕТИ =====

log "4. Перезапуск сетевой службы (network)"
systemctl restart network

echo
echo "Текущее состояние интерфейсов:"
ip a || echo "Предупреждение: команда 'ip a' завершилась с ошибкой."

echo
echo "Текущие маршруты:"
ip route || echo "Предупреждение: команда 'ip route' завершилась с ошибкой."

### ===== УСТАНОВКА IPTABLES И НАСТРОЙКА NAT =====

log "5. Установка iptables (если требуется) и настройка NAT"

# Если apt-get не найдётся, ALT может использовать другой менеджер, это можно будет подправить
if command -v apt-get >/dev/null 2>&1; then
    apt-get update || echo "Предупреждение: apt-get update завершился с ошибкой."
    apt-get install -y iptables || echo "Предупреждение: не удалось установить iptables через apt-get."
fi

# Спрашиваем сети, для которых делаем NAT
ask_with_default HQ_NET "Сеть HQ для NAT (CIDR, например 172.16.1.0/28)" "172.16.1.0/28"
ask_with_default BR_NET "Сеть BR для NAT (CIDR, например 172.16.2.0/28)" "172.16.2.0/28"

# Обнуляем цепочку POSTROUTING, чтобы не накапливать дубли
iptables -t nat -F POSTROUTING || true

iptables -t nat -A POSTROUTING -s "$HQ_NET" -o ens19 -j MASQUERADE
iptables -t nat -A POSTROUTING -s "$BR_NET" -o ens19 -j MASQUERADE

iptables-save > /etc/sysconfig/iptables || echo "Предупреждение: не удалось сохранить iptables в /etc/sysconfig/iptables."

systemctl enable --now iptables || echo "Предупреждение: не удалось включить сервис iptables."

echo
echo "Проверка NAT (таблица nat, цепочка POSTROUTING):"
iptables -t nat -L POSTROUTING -n -v || echo "Предупреждение: не удалось вывести iptables -t nat -L POSTROUTING."

### ===== ИТОГОВАЯ ПРОВЕРКА =====

log "6. Итоговая проверка связи с Интернетом (ping 8.8.8.8 -c 4)"

if ping -c 4 8.8.8.8 >/dev/null 2>&1; then
    echo "Интернет доступен (ping 8.8.8.8 успешен)."
else
    echo "Внимание: ping 8.8.8.8 не проходит. Проверь IP/маршрут/DNS у провайдера."
fi

echo ""
echo "=== Готово. ISP настроен (сетевые интерфейсы, NAT, часовой пояс). ==="
echo "Использованные значения:"
echo "  ens20 (к HQ-RTR): $ISP_HQ_NET_IP"
echo "  ens21 (к BR-RTR): $ISP_BR_NET_IP"
echo "  HQ сеть для NAT:  $HQ_NET"
echo "  BR сеть для NAT:  $BR_NET"
