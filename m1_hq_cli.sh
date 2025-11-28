#!/bin/bash
# M1: Настройка рабочей станции HQ-CLI (Alt Linux Workstation)
# - Настройка hostname
# - Настройка сетевого интерфейса (статический IP или DHCP)
# - Настройка временного DNS
# - Установка часового пояса Asia/Novosibirsk

set -e

# Аккуратно включаем pipefail, если оболочка поддерживает
if ( set -o 2>/dev/null | grep -q 'pipefail' ); then
  set -o pipefail
fi

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

log "1. Ввод параметров для HQ-CLI"

ask_with_default HOSTNAME_FQDN "FQDN рабочей станции (полное имя хоста)" "hq-cli.au-team.irpo"
ask_with_default NET_IFACE     "Имя сетевого интерфейса"                 "ens19"
ask_with_default TIMEZONE      "Часовой пояс (timedatectl)"             "Asia/Novosibirsk"

echo
read -rp "Использовать DHCP для ${NET_IFACE}? [y/N]: " USE_DHCP
USE_DHCP=${USE_DHCP:-N}

if [[ "$USE_DHCP" =~ ^[Yy]$ ]]; then
    NET_MODE="dhcp"
else
    NET_MODE="static"
fi

IPV4_ADDR=""
IPV4_GW=""
DNS_TMP=""

if [[ "$NET_MODE" == "static" ]]; then
    echo
    echo "Настройка статического IP для ${NET_IFACE}"
    echo "Важно: формат адреса с маской — в виде CIDR, например 192.168.200.10/24"
    ask_with_default IPV4_ADDR "IPv4 адрес/маска для ${NET_IFACE}" "192.168.200.10/24"
    ask_with_default IPV4_GW   "Шлюз по умолчанию"                  "192.168.200.1"
    ask_with_default DNS_TMP   "DNS-сервер (обычно HQ-SRV)"         "192.168.100.2"
fi

### ===== HOSTNAME =====

log "2. Настройка hostname"

hostnamectl set-hostname "${HOSTNAME_FQDN}"

NETWORK_CFG="/etc/sysconfig/network"
if [[ -f "$NETWORK_CFG" ]]; then
  if grep -q '^HOSTNAME=' "$NETWORK_CFG"; then
    sed -i "s/^HOSTNAME=.*/HOSTNAME=${HOSTNAME_FQDN}/" "$NETWORK_CFG"
  else
    echo "HOSTNAME=${HOSTNAME_FQDN}" >> "$NETWORK_CFG"
  fi
else
  echo "HOSTNAME=${HOSTNAME_FQDN}" > "$NETWORK_CFG"
fi

### ===== СЕТЕВОЙ ИНТЕРФЕЙС =====

log "3. Настройка сетевого интерфейса ${NET_IFACE}"

IFACE_DIR="/etc/net/ifaces/${NET_IFACE}"
mkdir -p "${IFACE_DIR}"

if [[ "$NET_MODE" == "dhcp" ]]; then
    echo "Режим: DHCP"
    cat > "${IFACE_DIR}/options" <<EOF
TYPE=eth
BOOTPROTO=dhcp
EOF
    # При DHCP статические файлы лучше убрать
    rm -f "${IFACE_DIR}/ipv4address" \
          "${IFACE_DIR}/ipv4route" \
          "${IFACE_DIR}/resolv.conf"
else
    echo "Режим: статический IP"
    cat > "${IFACE_DIR}/options" <<EOF
TYPE=eth
BOOTPROTO=static
EOF
    echo "${IPV4_ADDR}"        > "${IFACE_DIR}/ipv4address"
    echo "default via ${IPV4_GW}" > "${IFACE_DIR}/ipv4route"
    echo "nameserver ${DNS_TMP}"  > "${IFACE_DIR}/resolv.conf"
fi

log "4. Перезапуск сети"
systemctl restart network || echo "Внимание: не удалось перезапустить службу network"

### ===== ЧАСОВОЙ ПОЯС =====

log "5. Настройка часового пояса (${TIMEZONE})"

if command -v timedatectl >/dev/null 2>&1; then
  if ! timedatectl set-timezone "${TIMEZONE}"; then
    echo "Внимание: не удалось установить часовой пояс ${TIMEZONE}."
  fi
else
  echo "timedatectl не найден, пропускаю настройку таймзоны."
fi

### ===== РЕЗЮМЕ =====

log "6. РЕЗЮМЕ HQ-CLI"

echo "Hostname:"
hostname -f || echo "Не удалось получить полное имя хоста."
echo

echo "Интерфейс ${NET_IFACE}:"
ip addr show "${NET_IFACE}" || echo "Не удалось показать ip addr для ${NET_IFACE}"
echo

echo "Маршруты (default):"
ip route | grep default || echo "Default route не найден."
echo

if [[ "$NET_MODE" == "static" ]]; then
    echo "Файл resolv.conf для интерфейса (${IFACE_DIR}/resolv.conf):"
    cat "${IFACE_DIR}/resolv.conf" 2>/dev/null || echo "Файл resolv.conf не найден."
    echo
fi

echo "Часовой пояс:"
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl | grep 'Time zone' || echo "timedatectl есть, но строку Time zone не нашла."
else
  echo "timedatectl недоступен."
fi

echo
echo "HQ-CLI: базовая часть M1 (hostname, сеть, таймзона) выполнена."
echo "Для детального дебага запускай так: sudo bash -x ./m1_hq_cli.sh"
exit 0
