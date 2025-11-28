#!/bin/bash
# M1: BR-SRV базовая настройка (DEMO2026)
# Задачи:
#  - hostname + /etc/sysconfig/network
#  - IPv4 + шлюз + временный DNS (через /etc/net/ifaces/IFACE/*)
#  - часовой пояс
#  - локальные пользователи remote_user и sshuser (sshuser с UID 2026 и sudo без пароля)
#  - безопасный SSH: порт 2026, AllowUsers sshuser, MaxAuthTries=2, баннер

set -e

# Аккуратно включаем pipefail, если оболочка поддерживает
if ( set -o 2>/dev/null | grep -q 'pipefail' ); then
  set -o pipefail
fi

if [[ $EUID -ne 0 ]]; then
  echo "Запусти этот скрипт от root, например:"
  echo "  sudo bash m1_br_srv.sh"
  exit 1
fi

log() {
  echo ""
  echo "========== $* =========="
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

echo "=== M1: BR-SRV базовая настройка ==="

# ---------- Ввод параметров ----------

ask_with_default HOSTNAME_FQDN "FQDN сервера" "br-srv.au-team.irpo"

ask_with_default NET_IFACE "Имя сетевого интерфейса" "ens19"

echo "Формат адреса: 192.168.50.2/27 (IP/префикс)"
ask_with_default IPV4_ADDR "IPv4 адрес/маска для ${NET_IFACE}" "192.168.50.2/27"
ask_with_default IPV4_GW   "Шлюз по умолчанию"                  "192.168.50.1"
ask_with_default DNS_TMP   "Временный DNS-сервер"              "77.88.8.8"

ask_with_default TIMEZONE "Часовой пояс (timedatectl)" "Asia/Novosibirsk"

# Пользователи
ask_with_default REMOTE_USER "Имя локального пользователя (remote_user)" "remote_user"
echo "Пароль для ${REMOTE_USER} (символы не показываются):"
read -s REMOTE_PASS
echo

ask_with_default SSH_USER "Имя SSH-пользователя" "sshuser"
ask_with_default SSH_UID  "UID для ${SSH_USER}" "2026"
echo "Пароль для ${SSH_USER} (символы не показываются):"
read -s SSH_PASSWORD
echo

ask_with_default BANNER_TEXT "Текст баннера SSH" "Authorized access only"

SSHD_CONFIG="/etc/ssh/sshd_config"
SSH_BANNER_FILE="/etc/ssh/ssh_banner"
NETWORK_CFG="/etc/sysconfig/network"

# ---------- Hostname ----------

log "1. Настройка hostname"

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

log "2. Настройка IPv4 и временного DNS"

IFACE_DIR="/etc/net/ifaces/${NET_IFACE}"
if [[ ! -d "$IFACE_DIR" ]]; then
  echo "Каталог ${IFACE_DIR} не найден. Создаю его."
  mkdir -p "$IFACE_DIR"
fi

# options
cat > "${IFACE_DIR}/options" <<EOF
TYPE=eth
BOOTPROTO=static
EOF

echo "${IPV4_ADDR}"          > "${IFACE_DIR}/ipv4address"
echo "default via ${IPV4_GW}" > "${IFACE_DIR}/ipv4route"
echo "nameserver ${DNS_TMP}"  > "${IFACE_DIR}/resolv.conf"

systemctl restart network || echo "Внимание: не удалось перезапустить службу network"

# ---------- Часовой пояс ----------

log "3. Настройка часового пояса"

if command -v timedatectl >/dev/null 2>&1; then
  if ! timedatectl set-timezone "${TIMEZONE}"; then
    echo "Внимание: не удалось установить часовой пояс ${TIMEZONE}."
    echo "Проверь наличие пакета tzdata."
  fi
else
  echo "timedatectl не найден, пропускаю настройку таймзоны."
fi

# ---------- Локальные пользователи ----------

log "4. Создание пользователя ${REMOTE_USER}"

if id "${REMOTE_USER}" >/dev/null 2>&1; then
  echo "Пользователь ${REMOTE_USER} уже существует, пропускаю useradd."
else
  useradd -m -s /bin/bash "${REMOTE_USER}"
fi

if [[ -n "$REMOTE_PASS" ]]; then
  echo "${REMOTE_USER}:${REMOTE_PASS}" | chpasswd
else
  echo "Пароль для ${REMOTE_USER} не задан. Задай его вручную командой:"
  echo "  passwd ${REMOTE_USER}"
fi

log "5. Создание SSH-пользователя ${SSH_USER} (UID ${SSH_UID})"

if id "${SSH_USER}" >/dev/null 2>&1; then
  echo "Пользователь ${SSH_USER} уже существует, пропускаю useradd."
else
  useradd -m -u "${SSH_UID}" -s /bin/bash "${SSH_USER}"
fi

if [[ -n "$SSH_PASSWORD" ]]; then
  echo "${SSH_USER}:${SSH_PASSWORD}" | chpasswd
else
  echo "Пароль пустой. Задай его командой: passwd ${SSH_USER}"
fi

# Добавляем sshuser в wheel
if getent group wheel >/dev/null 2>&1; then
  usermod -aG wheel "${SSH_USER}"
else
  echo "Группа wheel не найдена, создаю её."
  groupadd wheel
  usermod -aG wheel "${SSH_USER}"
fi

# Разрешаем wheel sudo без пароля
SUDOERS_FILE="/etc/sudoers"
if ! grep -q '^%wheel ALL=(ALL) NOPASSWD: ALL' "$SUDOERS_FILE"; then
  sed -i 's/^%wheel ALL=(ALL) ALL/# %wheel ALL=(ALL) ALL/' "$SUDOERS_FILE" || true
  echo "%wheel ALL=(ALL) NOPASSWD: ALL" >> "$SUDOERS_FILE"
fi

# ---------- Безопасный SSH ----------

log "6. Настройка защищённого SSH"

if [[ ! -f "$SSHD_CONFIG" ]]; then
  echo "Файл ${SSHD_CONFIG} не найден."
  echo "Установи пакет openssh-server и запусти скрипт ещё раз."
else
  cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%F_%H-%M-%S)"

  # Port 2026
  if grep -qE '^[# ]*Port ' "$SSHD_CONFIG"; then
    sed -i 's/^[# ]*Port .*/Port 2026/' "$SSHD_CONFIG"
  else
    echo "Port 2026" >> "$SSHD_CONFIG"
  fi

  # AllowUsers только sshuser
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

  systemctl restart sshd || echo "Внимание: не удалось перезапустить sshd"
fi

# ---------- Итоговый вывод ----------

log "7. РЕЗЮМЕ BR-SRV"

echo "Hostname:"
hostname -f || echo "Не удалось получить полное имя хоста."
echo

echo "Сетевой интерфейс ${NET_IFACE}:"
ip addr show "${NET_IFACE}" || echo "Не удалось показать ip addr для ${NET_IFACE}"
echo

echo "Маршруты по умолчанию:"
ip route | grep default || echo "Default route не найден."
echo

echo "DNS (resolv.conf для интерфейса ${NET_IFACE}):"
cat "${IFACE_DIR}/resolv.conf" 2>/dev/null || echo "Файл ${IFACE_DIR}/resolv.conf не найден."
echo

echo "Часовой пояс:"
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl | grep 'Time zone' || echo "timedatectl есть, но строку Time zone не нашла."
else
  echo "timedatectl недоступен."
fi
echo

echo "Пользователь ${REMOTE_USER}:"
id "${REMOTE_USER}" || echo "Пользователь не найден."
echo

echo "Пользователь ${SSH_USER}:"
id "${SSH_USER}" || echo "Пользователь не найден."
echo

echo "Фрагмент sudoers (wheel):"
grep wheel /etc/sudoers || echo "Не нашла строку про wheel в /etc/sudoers, проверь вручную."
echo

echo "Ключевые строки sshd_config:"
if [[ -f "$SSHD_CONFIG" ]]; then
  grep -E 'Port 2026|AllowUsers|MaxAuthTries|Banner' "${SSHD_CONFIG}" || echo "Не нашла нужные строки в ${SSHD_CONFIG}"
else
  echo "Файл ${SSHD_CONFIG} отсутствует."
fi
echo

echo "BR-SRV: базовая часть Модуля 1 выполнена."
echo "Для детального дебага запускай так: sudo bash -x ./m1_br_srv.sh"
exit 0
