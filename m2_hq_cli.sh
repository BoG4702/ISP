#!/bin/bash
# M1: Nastrojka rabochey stancii HQ-CLI (Alt Linux Workstation)
# - Nastrojka hostname
# - Nastrojka setevogo interfejsa (staticheskij IP ili DHCP)
# - Nastrojka vremennogo DNS
# - Ustanovka chasovogo poyasa Asia/Novosibirsk

set -e

# Akkuratno vklyuchaem pipefail, esli obolochka podderzhivaet
if ( set -o 2>/dev/null | grep -q 'pipefail' ); then
  set -o pipefail
fi

### ===== VSPOMOGATELNYE FUNKCII =====

log() {
    echo ""
    echo "========== $* =========="
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        echo "Oshibka: skript nuzhno zapuskat ot root (sudo ili pod uchetkoj root)." >&2
        exit 1
    fi
}

ask_with_default() {
    # $1 - imya peremennoj, $2 - tekst voprosa, $3 - znachenie po umolchaniyu
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

### ===== PROVERKI =====

require_root

log "1. Vvod parametrov dlya HQ-CLI"

ask_with_default HOSTNAME_FQDN "FQDN rabochey stancii (polnoe imya hosta)" "hq-cli.au-team.irpo"
ask_with_default NET_IFACE     "Imya setevogo interfejsa"                  "ens19"
ask_with_default TIMEZONE      "Chasovoy poyas (timedatectl)"              "Asia/Novosibirsk"

echo
read -rp "Ispolzovat DHCP dlya ${NET_IFACE}? [y/N]: " USE_DHCP
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
    echo "Nastrojka staticheskogo IP dlya ${NET_IFACE}"
    echo "Vazhno: format adresa s maskoy - v vide CIDR, naprimer 192.168.200.10/24"
    ask_with_default IPV4_ADDR "IPv4 adres/maska dlya ${NET_IFACE}" "192.168.200.10/24"
    ask_with_default IPV4_GW   "Shlyuz po umolchaniyu"               "192.168.200.1"
    ask_with_default DNS_TMP   "DNS-server (obychno HQ-SRV)"         "192.168.100.2"
fi

### ===== HOSTNAME =====

log "2. Nastrojka hostname"

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

### ===== SETEVOY INTERFEJS =====

log "3. Nastrojka setevogo interfejsa ${NET_IFACE}"

IFACE_DIR="/etc/net/ifaces/${NET_IFACE}"
mkdir -p "${IFACE_DIR}"

if [[ "$NET_MODE" == "dhcp" ]]; then
    echo "Rezhim: DHCP"
    cat > "${IFACE_DIR}/options" <<EOF
TYPE=eth
BOOTPROTO=dhcp
EOF
    # Pri DHCP staticheskie fayly luchshe ubrat
    rm -f "${IFACE_DIR}/ipv4address" \
          "${IFACE_DIR}/ipv4route" \
          "${IFACE_DIR}/resolv.conf"
else
    echo "Rezhim: staticheskij IP"
    cat > "${IFACE_DIR}/options" <<EOF
TYPE=eth
BOOTPROTO=static
EOF
    echo "${IPV4_ADDR}"           > "${IFACE_DIR}/ipv4address"
    echo "default via ${IPV4_GW}" > "${IFACE_DIR}/ipv4route"
    echo "nameserver ${DNS_TMP}"  > "${IFACE_DIR}/resolv.conf"
fi

log "4. Perezapusk seti"
systemctl restart network || echo "Vnimanie: ne udalos perezapustit sluzhbu network"

### ===== CHASOVOY POYAS =====

log "5. Nastrojka chasovogo poyasa (${TIMEZONE})"

if command -v timedatectl >/dev/null 2>&1; then
  if ! timedatectl set-timezone "${TIMEZONE}"; then
    echo "Vnimanie: ne udalos ustanovit chasovoy poyas ${TIMEZONE}."
  fi
else
  echo "timedatectl ne nayden, propuskayu nastrojku tajmzony."
fi

### ===== REZYUME =====

log "6. REZYUME HQ-CLI"

echo "Hostname:"
hostname -f || echo "Ne udalos poluchit polnoe imya hosta."
echo

echo "Interfejs ${NET_IFACE}:"
ip addr show "${NET_IFACE}" || echo "Ne udalos pokazat ip addr dlya ${NET_IFACE}"
echo

echo "Marshruty (default):"
ip route | grep default || echo "Default route ne nayden."
echo

if [[ "$NET_MODE" == "static" ]]; then
    echo "Fayl resolv.conf dlya interfejsa (${IFACE_DIR}/resolv.conf):"
    cat "${IFACE_DIR}/resolv.conf" 2>/dev/null || echo "Fayl resolv.conf ne nayden."
    echo
fi

echo "Chasovoy poyas:"
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl | grep 'Time zone' || echo "timedatectl est, no stroku Time zone ne nashla."
else
  echo "timedatectl nedostupen."
fi

echo
echo "HQ-CLI: bazovaya chast M1 (hostname, set, tajmzona) vypolnena."
echo "Dlya detalnogo debaga zapuskaj tak: sudo bash -x ./m1_hq_cli.sh"
exit 0
