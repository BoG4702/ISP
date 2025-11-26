#!/bin/bash
# M1: HQ-SRV базовая настройка (DEMO2026)
# Задачи:
#  - hostname + /etc/sysconfig/network
#  - IPv4 + шлюз + временный DNS (через /etc/net/ifaces/IFACE/*)
#  - часовой пояс
#  - локальный пользователь для SSH (UID 2026) с sudo без пароля
#  - безопасный SSH: порт 2026, AllowUsers, MaxAuthTries=2, баннер

set -e

if [[ $EUID -ne 0 ]]; then
  echo "Запусти этот скрипт от root, например:"
  echo "  sudo bash m1_hq_srv.sh"
  exit 1
fi

echo "=== M1: HQ-SRV базовая настройка ==="

# ---------- Ввод параметров ----------

read -p "FQDN сервера [hq-srv.au-team.irpo]: " HOSTNAME_FQDN
HOSTNAME_FQDN=${HOSTNAME_FQDN:-hq-srv.au-team.irpo}

read -p "Имя сетевого интерфейса [ens19]: " NET_IFACE
NET_IFACE=${NET_IFACE:-ens19}

read -p "IPv4 адрес/маска для ${NET_IFACE} [192.168.100.2/27]: " IPV4_ADDR
IPV4_ADDR=${IPV4_ADDR:-192.168.100.2/27}

read -p "Шлюз по умолчанию [192.168.100.1]: " IPV4_GW
IPV4_GW=${IPV4_GW:-192.168.100.1}

read -p "Временный DNS-сервер [77.88.8.8]: " DNS_TMP
DNS_TMP=${DNS_TMP:-77.88.8.8}

read -p "Часовой пояс (timedatectl) [Asia/Novosibirsk]: " TIMEZONE
TIMEZONE=${TIMEZONE:-Asia/Novosibirsk}
# На экзамене можно поменять на Europe/Moscow

read -p "Имя SSH-пользователя [sshuser]: " SSH_USER
SSH_USER=${SSH_USER:-sshuser}

read -p "UID для ${SSH_USER} [2026]: " SSH_UID
SSH_UID=${SSH_UID:-2026}

echo "Пароль для ${SSH_USER} (символы не показываются):"
read -s SSH_PASSWORD
echo

read -p "Текст баннера SSH [Authorized access only]: " BANNER_TEXT
BANNER_TEXT=${BANNER_TEXT:-Authorized access only}

SSHD_CONFIG="/etc/ssh/sshd_config"
SSH_BANNER_FILE="/etc/ssh/ssh_banner"
NETWORK_CFG="/etc/sysconfig/network"

# ---------- Hostname ----------

echo "== Настраиваю hostname =="
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

echo "== Настраиваю IPv4 и временный DNS =="

IFACE_DIR="/etc/net/ifaces/${NET_IFACE}"
if [[ ! -d "$IFACE_DIR" ]]; then
  echo "Каталог ${IFACE_DIR} не найден. Создаю его."
  mkdir -p "$IFACE_DIR"
fi

echo "${IPV4_ADDR}" > "${IFACE_DIR}/ipv4address"
echo "default via ${IPV4_GW}" > "${IFACE_DIR}/ipv4route"
echo "nameserver ${DNS_TMP}" > "${IFACE_DIR}/resolv.conf"

systemctl restart network || echo "Внимание: не удалось перезапустить службу network"

# ---------- Часовой пояс ----------

echo "== Настраиваю часовой пояс =="
if command -v timedatectl >/dev/null 2>&1; then
  if ! timedatectl set-timezone "${TIMEZONE}"; then
    echo "Внимание: не удалось установить часовой пояс ${TIMEZONE}."
    echo "Проверь наличие пакета tzdata."
  fi
else
  echo "timedatectl не найден, пропускаю настройку таймзоны."
fi

# ---------- Локальный пользователь + sudo ----------

echo "== Создаю пользователя ${SSH_USER} с UID ${SSH_UID} =="

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

# Добавляем в wheel
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

echo "== Настраиваю защищённый SSH =="

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

  # AllowUsers
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

echo
echo "===== РЕЗЮМЕ HQ-SRV ====="
echo "Hostname: $(hostname -f)"
echo

echo "Сетевой интерфейс ${NET_IFACE}:"
ip addr show "${NET_IFACE}" || echo "Не удалось показать ip addr для ${NET_IFACE}"
echo

echo "Маршруты по умолчанию:"
ip route | grep default || echo "Default route не найден."
echo

echo "DNS (resolv.conf для ${NET_IFACE}):"
cat "${IFACE_DIR}/resolv.conf" 2>/dev/null || echo "Файл ${IFACE_DIR}/resolv.conf не найден."
echo

echo "Часовой пояс:"
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl | grep 'Time zone' || echo "timedatectl есть, но строку Time zone не нашла."
else
  echo "timedatectl недоступен."
fi
echo

echo "Пользователь ${SSH_USER}:"
id "${SSH_USER}" || echo "Пользователь не найден."
echo

echo "Запись в sudoers:"
grep wheel /etc/sudoers || echo "Не нашла строку про wheel в /etc/sudoers, проверь вручную."
echo

echo "Ключевые строки sshd_config:"
if [[ -f "$SSHD_CONFIG" ]]; then
  grep -E 'Port 2026|AllowUsers|MaxAuthTries|Banner' "${SSHD_CONFIG}" || echo "Не нашла нужные строки в ${SSHD_CONFIG}"
else
  echo "Файл ${SSHD_CONFIG} отсутствует."
fi
echo

echo "HQ-SRV: базовая часть Модуля 1 выполнена."
echo "Для детального дебага запускай так: bash -x m1_hq_srv.sh"

exit 0
