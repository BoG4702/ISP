#!/bin/bash
# M1: BR-SRV bazovaya nastrojka (DEMO2026)
# Zadachi:
#  - hostname + /etc/sysconfig/network
#  - IPv4 + shlyuz + vremennyy DNS (cherez /etc/net/ifaces/IFACE/*)
#  - chasovoy poyas
#  - lokalnye polzovateli remote_user i sshuser (sshuser s UID 2026 i sudo bez parolya)
#  - bezopasnyy SSH: port 2026, AllowUsers sshuser, MaxAuthTries=2, banner

set -e

# Akkuratno vklyuchaem pipefail, esli obolochka podderzhivaet
if ( set -o 2>/dev/null | grep -q 'pipefail' ); then
  set -o pipefail
fi

if [[ $EUID -ne 0 ]]; then
  echo "Zapusti etot skript ot root, naprimer:"
  echo "  sudo bash m1_br_srv.sh"
  exit 1
fi

log() {
  echo ""
  echo "========== $* =========="
}

ask_with_default() {
  # $1 - imya peremennoy, $2 - tekst voprosa, $3 - znachenie po umolchaniyu
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

echo "=== M1: BR-SRV bazovaya nastrojka ==="

# ---------- Vvod parametrov ----------

ask_with_default HOSTNAME_FQDN "FQDN servera" "br-srv.au-team.irpo"

ask_with_default NET_IFACE "Imya setevogo interfejsa" "ens19"

echo "Format adresa: 192.168.50.2/27 (IP/prefiks)"
ask_with_default IPV4_ADDR "IPv4 adres/maska dlya ${NET_IFACE}" "192.168.50.2/27"
ask_with_default IPV4_GW   "Shlyuz po umolchaniyu"                 "192.168.50.1"
ask_with_default DNS_TMP   "Vremennyy DNS-server"                  "77.88.8.8"

ask_with_default TIMEZONE "Chasovoy poyas (timedatectl)" "Asia/Novosibirsk"

# Polzovateli
ask_with_default REMOTE_USER "Imya lokalnogo polzovatelya (remote_user)" "remote_user"
echo "Parol dlya ${REMOTE_USER} (simvoly ne pokazyvayutsya):"
read -s REMOTE_PASS
echo

ask_with_default SSH_USER "Imya SSH-polzovatelya" "sshuser"
ask_with_default SSH_UID  "UID dlya ${SSH_USER}" "2026"
echo "Parol dlya ${SSH_USER} (simvoly ne pokazyvayutsya):"
read -s SSH_PASSWORD
echo

ask_with_default BANNER_TEXT "Tekst bannera SSH" "Authorized access only"

SSHD_CONFIG="/etc/ssh/sshd_config"
SSH_BANNER_FILE="/etc/ssh/ssh_banner"
NETWORK_CFG="/etc/sysconfig/network"

# ---------- Hostname ----------

log "1. Nastrojka hostname"

hostnamectl set-hostname "${HOSTNAME_FQDN}"

if [[ -f "$NETWORK_CFG" ]]; then
  if grep -q '^HOSTNAME=' "$NETWORK_CFG"; then
    sed -i "s/^HOSTNAME=.*/HOSTNAME=${HOSTNAME_FQDN}/" "$NETWORK_CFG"
  else
    echo "HOSTNAME=${HOSTNAME_FQDN}" >> "$NETWORK_CFG"
  fi
else
  echo "HOSTNAME=${HOSTNAME_FQDN}" > "$NETWORK_CFG"
fi

# ---------- IPv4 + DNS ----------

log "2. Nastrojka IPv4 i vremennogo DNS"

IFACE_DIR="/etc/net/ifaces/${NET_IFACE}"
if [[ ! -d "$IFACE_DIR" ]]; then
  echo "Katalog ${IFACE_DIR} ne nayden. Sozdayu ego."
  mkdir -p "$IFACE_DIR"
fi

# options
cat > "${IFACE_DIR}/options" <<EOF
TYPE=eth
BOOTPROTO=static
EOF

echo "${IPV4_ADDR}"           > "${IFACE_DIR}/ipv4address"
echo "default via ${IPV4_GW}" > "${IFACE_DIR}/ipv4route"
echo "nameserver ${DNS_TMP}"  > "${IFACE_DIR}/resolv.conf"

systemctl restart network || echo "Vnimanie: ne udalos perezapustit sluzhbu network"

# ---------- Chasovoy poyas ----------

log "3. Nastrojka chasovogo poyasa"

if command -v timedatectl >/dev/null 2>&1; then
  if ! timedatectl set-timezone "${TIMEZONE}"; then
    echo "Vnimanie: ne udalos ustanovit chasovoy poyas ${TIMEZONE}."
    echo "Prover nalichie paketa tzdata."
  fi
else
  echo "timedatectl ne nayden, propuskayu nastrojku tajmzony."
fi

# ---------- Lokalnye polzovateli ----------

log "4. Sozdanie polzovatelya ${REMOTE_USER}"

if id "${REMOTE_USER}" >/dev/null 2>&1; then
  echo "Polzovatel ${REMOTE_USER} uzhe suschestvuet, propuskayu useradd."
else
  useradd -m -s /bin/bash "${REMOTE_USER}"
fi

if [[ -n "$REMOTE_PASS" ]]; then
  echo "${REMOTE_USER}:${REMOTE_PASS}" | chpasswd
else
  echo "Parol dlya ${REMOTE_USER} ne zadan. Zaday ego v ruchnuyu komandoj:"
  echo "  passwd ${REMOTE_USER}"
fi

log "5. Sozdanie SSH-polzovatelya ${SSH_USER} (UID ${SSH_UID})"

if id "${SSH_USER}" >/dev/null 2>&1; then
  echo "Polzovatel ${SSH_USER} uzhe suschestvuet, propuskayu useradd."
else
  useradd -m -u "${SSH_UID}" -s /bin/bash "${SSH_USER}"
fi

if [[ -n "$SSH_PASSWORD" ]]; then
  echo "${SSH_USER}:${SSH_PASSWORD}" | chpasswd
else
  echo "Parol pustoy. Zaday ego komandoj: passwd ${SSH_USER}"
fi

# Dobavlyaem sshuser v wheel
if getent group wheel >/dev/null 2>&1; then
  usermod -aG wheel "${SSH_USER}"
else
  echo "Gruppa wheel ne naydena, sozdayu ee."
  groupadd wheel
  usermod -aG wheel "${SSH_USER}"
fi

# Razreshaem wheel sudo bez parolya
SUDOERS_FILE="/etc/sudoers"
if ! grep -q '^%wheel ALL=(ALL) NOPASSWD: ALL' "$SUDOERS_FILE"; then
  sed -i 's/^%wheel ALL=(ALL) ALL/# %wheel ALL=(ALL) ALL/' "$SUDOERS_FILE" || true
  echo "%wheel ALL=(ALL) NOPASSWD: ALL" >> "$SUDOERS_FILE"
fi

# ---------- Bezopasnyy SSH ----------

log "6. Nastrojka zashchishchennogo SSH"

if [[ ! -f "$SSHD_CONFIG" ]]; then
  echo "Fayl ${SSHD_CONFIG} ne nayden."
  echo "Ustanovi paket openssh-server i zapusti skript eshche raz."
else
  cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%F_%H-%M-%S)"

  # Port 2026
  if grep -qE '^[# ]*Port ' "$SSHD_CONFIG"; then
    sed -i 's/^[# ]*Port .*/Port 2026/' "$SSHD_CONFIG"
  else
    echo "Port 2026" >> "$SSHD_CONFIG"
  fi

  # AllowUsers tolko sshuser
  if grep -qE '^[# ]*AllowUsers ' "$SSHD_CONFIG"; then
    sed -i "s/^[# ]*AllowUsers .*/AllowUsers ${SSH_USER}/" "$SSHD_CONFIG"
  else
    echo "AllowUsers ${SSH_USER}" >> "$SSHD_CONFIG"
  fi

  # MaxAuthTries 2
  if grep -qE '^[# ]*MaxAuthTries ' "$SSHD_CONFIG"; then
    sed -i 's/^[# ]*MaxAuthTries .*/MaxAuthTries 2/' "$SSHD_CONFIG"
  else
    echo "MaxAuthTries 2" >> "$SSHD_CONFIG"
  fi

  # Banner
  echo "${BANNER_TEXT}" > "${SSH_BANNER_FILE}"
  if grep -qE '^[# ]*Banner ' "$SSHD_CONFIG"; then
    sed -i "s|^[# ]*Banner .*|Banner ${SSH_BANNER_FILE}|" "$SSHD_CONFIG"
  else
    echo "Banner ${SSH_BANNER_FILE}" >> "$SSHD_CONFIG"
  fi

  systemctl restart sshd || echo "Vnimanie: ne udalos perezapustit sshd"
fi

# ---------- Itogovyy vyvod ----------

log "7. REZYUME BR-SRV"

echo "Hostname:"
hostname -f || echo "Ne udalos pokazat polnoe imya hosta."
echo

echo "Setevoy interfejs ${NET_IFACE}:"
ip addr show "${NET_IFACE}" || echo "Ne udalos pokazat ip addr dlya ${NET_IFACE}"
echo

echo "Marshruty po umolchaniyu:"
ip route | grep default || echo "Default route ne nayden."
echo

echo "DNS (resolv.conf dlya interfejsa ${NET_IFACE}):"
cat "${IFACE_DIR}/resolv.conf" 2>/dev/null || echo "Fayl ${IFACE_DIR}/resolv.conf ne nayden."
echo

echo "Chasovoy poyas:"
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl | grep 'Time zone' || echo "timedatectl est, no stroku Time zone ne nashla."
else
  echo "timedatectl nedostupen."
fi
echo

echo "Polzovatel ${REMOTE_USER}:"
id "${REMOTE_USER}" || echo "Polzovatel ne nayden."
echo

echo "Polzovatel ${SSH_USER}:"
id "${SSH_USER}" || echo "Polzovatel ne nayden."
echo

echo "Fragment sudoers (wheel):"
grep wheel /etc/sudoers || echo "Ne nashla stroku pro wheel v /etc/sudoers, prover v ruchnuyu."
echo

echo "Klyuchevye stroki sshd_config:"
if [[ -f "$SSHD_CONFIG" ]]; then
  grep -E 'Port 2026|AllowUsers|MaxAuthTries|Banner' "${SSHD_CONFIG}" || echo "Ne nashla nuzhnye stroki v ${SSHD_CONFIG}"
else
  echo "Fayl ${SSHD_CONFIG} otsutstvuet."
fi
echo

echo "BR-SRV: bazovaya chast Modulya 1 vypolnena."
echo "Dlya detalnogo debaga zapuskaj tak: sudo bash -x ./m1_br_srv.sh"
exit 0
