#!/usr/bin/env bash
set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${BOOTSTRAP_ENV:-${SCRIPT_DIR}/.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  source "${CONFIG_FILE}"
else
  echo "[WARN] Config file not found: ${CONFIG_FILE}"
  echo "[WARN] Using built-in defaults"
fi

TIMEZONE="${TIMEZONE:-Europe/Amsterdam}"
SET_HOSTNAME="${SET_HOSTNAME:-}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
ADMIN_PUBKEY="${ADMIN_PUBKEY:-}"
ENABLE_PASSWORDLESS_SUDO="${ENABLE_PASSWORDLESS_SUDO:-true}"
SSH_PORT="${SSH_PORT:-22}"

ENABLE_UFW="${ENABLE_UFW:-true}"
UFW_DEFAULT_INCOMING="${UFW_DEFAULT_INCOMING:-deny}"
UFW_DEFAULT_OUTGOING="${UFW_DEFAULT_OUTGOING:-allow}"
EXTRA_TCP_PORTS="${EXTRA_TCP_PORTS:-80,443}"
EXTRA_UDP_PORTS="${EXTRA_UDP_PORTS:-}"

ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
ENABLE_UNATTENDED_UPGRADES="${ENABLE_UNATTENDED_UPGRADES:-true}"
ENABLE_DOCKER="${ENABLE_DOCKER:-true}"
ENABLE_SWAPFILE="${ENABLE_SWAPFILE:-false}"
SWAPFILE_SIZE_GB="${SWAPFILE_SIZE_GB:-2}"
INSTALL_EXTRA_PACKAGES="${INSTALL_EXTRA_PACKAGES:-true}"

APT_RETRIES="${APT_RETRIES:-5}"
APT_RETRY_DELAY="${APT_RETRY_DELAY:-15}"

BASIC_PACKAGES=(
  ca-certificates
  curl
  wget
  gnupg
  lsb-release
  apt-transport-https
  software-properties-common
  openssh-server
  sudo
  ufw
  fail2ban
  unattended-upgrades
  needrestart
  git
  jq
  unzip
  zip
  tmux
  htop
  mc
  nano
  vim
  rsync
  cron
  bash-completion
  net-tools
  dnsutils
  traceroute
  tcpdump
  ncdu
)

log()  { echo -e "\n\033[1;32m[INFO]\033[0m $*"; }
warn() { echo -e "\n\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\n\033[1;31m[ERR ]\033[0m $*" >&2; }

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Run as root: sudo bash $0"
    exit 1
  fi
}

str_true() {
  [[ "${1,,}" == "true" ]]
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

wait_for_apt_locks() {
  local waited=0
  local max_wait=600

  while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
     || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
     || fuser /var/cache/apt/archives/lock >/dev/null 2>&1 \
     || pgrep -x apt >/dev/null 2>&1 \
     || pgrep -x apt-get >/dev/null 2>&1 \
     || pgrep -x dpkg >/dev/null 2>&1; do
    warn "apt/dpkg lock detected, waiting... (${waited}s)"
    sleep 5
    waited=$((waited + 5))

    if (( waited >= max_wait )); then
      err "Timed out waiting for apt/dpkg lock"
      return 1
    fi
  done
}

apt_get_with_retry() {
  local attempt=1
  local max_attempts="${APT_RETRIES}"
  local base_delay="${APT_RETRY_DELAY}"

  while true; do
    wait_for_apt_locks

    if apt-get \
      -o DPkg::Lock::Timeout=60 \
      -o Acquire::Retries=5 \
      -o Dpkg::Use-Pty=0 \
      "$@"; then
      return 0
    fi

    if (( attempt >= max_attempts )); then
      err "apt-get $* failed after ${max_attempts} attempts"
      return 1
    fi

    local sleep_for=$((attempt * base_delay))
    warn "apt-get $* failed (attempt ${attempt}/${max_attempts}), retrying in ${sleep_for}s"
    sleep "${sleep_for}"
    attempt=$((attempt + 1))
  done
}

apt_update() {
  log "Updating apt index"
  apt_get_with_retry update -y
}

apt_full_upgrade() {
  log "Upgrading system"
  apt_get_with_retry full-upgrade --fix-missing -y
}

apt_install() {
  apt_get_with_retry install -y "$@"
}

apt_remove() {
  apt_get_with_retry remove -y "$@" || true
}

apt_update_upgrade() {
  apt_update
  apt_full_upgrade

  if str_true "$INSTALL_EXTRA_PACKAGES"; then
    log "Installing base packages"
    apt_install "${BASIC_PACKAGES[@]}"
  fi

  apt-get autoremove -y || true
  apt-get autoclean -y || true
}

set_timezone() {
  if [[ -n "${TIMEZONE}" ]]; then
    log "Setting timezone: ${TIMEZONE}"
    timedatectl set-timezone "${TIMEZONE}" || warn "Could not set timezone"
  fi
}

set_hostname_if_needed() {
  if [[ -n "${SET_HOSTNAME}" ]]; then
    log "Setting hostname: ${SET_HOSTNAME}"
    hostnamectl set-hostname "${SET_HOSTNAME}"
  fi
}

ensure_admin_user() {
  log "Ensuring admin user: ${ADMIN_USER}"

  if id -u "${ADMIN_USER}" >/dev/null 2>&1; then
    log "User ${ADMIN_USER} already exists"
  else
    adduser --disabled-password --gecos "" "${ADMIN_USER}"
  fi

  usermod -aG sudo "${ADMIN_USER}"

  if [[ -n "${ADMIN_PASSWORD}" ]]; then
    echo "${ADMIN_USER}:${ADMIN_PASSWORD}" | chpasswd
  fi

  install -d -m 0700 -o "${ADMIN_USER}" -g "${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh"

  if [[ -n "${ADMIN_PUBKEY}" ]] && [[ "${ADMIN_PUBKEY}" != *"REPLACE_ME_WITH_YOUR_PUBLIC_KEY"* ]]; then
    touch "/home/${ADMIN_USER}/.ssh/authorized_keys"
    chmod 600 "/home/${ADMIN_USER}/.ssh/authorized_keys"
    chown "${ADMIN_USER}:${ADMIN_USER}" "/home/${ADMIN_USER}/.ssh/authorized_keys"

    if ! grep -Fqx "${ADMIN_PUBKEY}" "/home/${ADMIN_USER}/.ssh/authorized_keys"; then
      echo "${ADMIN_PUBKEY}" >> "/home/${ADMIN_USER}/.ssh/authorized_keys"
      log "SSH key installed for ${ADMIN_USER}"
    fi
  else
    warn "ADMIN_PUBKEY is empty or placeholder"
  fi

  if str_true "${ENABLE_PASSWORDLESS_SUDO}"; then
    cat > "/etc/sudoers.d/90-${ADMIN_USER}" <<EOF_SUDO
${ADMIN_USER} ALL=(ALL:ALL) NOPASSWD:ALL
EOF_SUDO
    chmod 440 "/etc/sudoers.d/90-${ADMIN_USER}"
  fi
}

sshd_set_option_in_file() {
  local file="$1"
  local key="$2"
  local value="$3"

  touch "$file"

  if grep -qiE "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -ri "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|I" "$file"
  else
    echo "${key} ${value}" >> "$file"
  fi
}

sshd_set_option() {
  local key="$1"
  local value="$2"
  local file="/etc/ssh/sshd_config"

  if grep -qiE "^[#[:space:]]*${key}[[:space:]]+" "$file"; then
    sed -ri "s|^[#[:space:]]*${key}[[:space:]]+.*|${key} ${value}|I" "$file"
  else
    echo "${key} ${value}" >> "$file"
  fi
}

configure_ssh() {
  log "Configuring SSH"

  mkdir -p /etc/ssh/sshd_config.d

  local password_auth="yes"
  local root_login="yes"

  if [[ -n "${ADMIN_PUBKEY}" ]] && [[ "${ADMIN_PUBKEY}" != *"REPLACE_ME_WITH_YOUR_PUBLIC_KEY"* ]]; then
    password_auth="no"
    root_login="no"
  fi

  cat > /etc/ssh/sshd_config.d/99-bootstrap.conf <<EOF_SSH
Port ${SSH_PORT}
Protocol 2

PermitRootLogin ${root_login}
PasswordAuthentication ${password_auth}
KbdInteractiveAuthentication no
PubkeyAuthentication yes
ChallengeResponseAuthentication no
UsePAM yes

X11Forwarding no
PrintMotd no
ClientAliveInterval 300
ClientAliveCountMax 2
MaxAuthTries 3
LoginGraceTime 30
EOF_SSH

  cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bootstrap.bak

  sshd_set_option "Port" "${SSH_PORT}"
  sshd_set_option "PermitRootLogin" "${root_login}"
  sshd_set_option "PasswordAuthentication" "${password_auth}"
  sshd_set_option "KbdInteractiveAuthentication" "no"
  sshd_set_option "PubkeyAuthentication" "yes"
  sshd_set_option "ChallengeResponseAuthentication" "no"
  sshd_set_option "UsePAM" "yes"
  sshd_set_option "X11Forwarding" "no"
  sshd_set_option "PrintMotd" "no"
  sshd_set_option "ClientAliveInterval" "300"
  sshd_set_option "ClientAliveCountMax" "2"
  sshd_set_option "MaxAuthTries" "3"
  sshd_set_option "LoginGraceTime" "30"

  if [[ "${password_auth}" == "no" ]]; then
    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
      cat > /etc/cloud/cloud.cfg.d/99-bootstrap-disable-ssh-password-auth.cfg <<'EOF_CLOUD'
ssh_pwauth: false
EOF_CLOUD
    fi

    if [[ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]]; then
      sshd_set_option_in_file "/etc/ssh/sshd_config.d/50-cloud-init.conf" "PasswordAuthentication" "no"
      sshd_set_option_in_file "/etc/ssh/sshd_config.d/50-cloud-init.conf" "KbdInteractiveAuthentication" "no"
      sshd_set_option_in_file "/etc/ssh/sshd_config.d/50-cloud-init.conf" "PubkeyAuthentication" "yes"
    fi
  fi

  if /usr/sbin/sshd -t; then
    systemctl enable ssh
    systemctl restart ssh || systemctl restart sshd || true
  else
    err "Invalid ssh config"
    exit 1
  fi
}

ufw_allow_csv_ports() {
  local proto="$1"
  local csv="$2"
  local item

  IFS=',' read -r -a arr <<< "${csv}"
  for item in "${arr[@]}"; do
    item="$(trim "${item}")"
    [[ -z "${item}" ]] && continue
    ufw allow "${item}/${proto}"
  done
}

configure_ufw() {
  if ! str_true "${ENABLE_UFW}"; then
    warn "UFW disabled by config"
    return
  fi

  log "Configuring UFW"
  ufw --force reset
  ufw default "${UFW_DEFAULT_INCOMING}" incoming
  ufw default "${UFW_DEFAULT_OUTGOING}" outgoing
  ufw allow "${SSH_PORT}/tcp"

  [[ -n "${EXTRA_TCP_PORTS}" ]] && ufw_allow_csv_ports "tcp" "${EXTRA_TCP_PORTS}"
  [[ -n "${EXTRA_UDP_PORTS}" ]] && ufw_allow_csv_ports "udp" "${EXTRA_UDP_PORTS}"

  ufw --force enable
}

configure_fail2ban() {
  if ! str_true "${ENABLE_FAIL2BAN}"; then
    warn "fail2ban disabled by config"
    return
  fi

  log "Configuring fail2ban"
  mkdir -p /etc/fail2ban/jail.d

  cat > /etc/fail2ban/jail.d/sshd.local <<EOF_F2B
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF_F2B

  systemctl enable fail2ban
  systemctl restart fail2ban
}

configure_unattended_upgrades() {
  if ! str_true "${ENABLE_UNATTENDED_UPGRADES}"; then
    warn "unattended-upgrades disabled by config"
    return
  fi

  log "Configuring unattended-upgrades"
  apt_install unattended-upgrades

  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF_UPD'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF_UPD

  cat > /etc/apt/apt.conf.d/52unattended-upgrades-local <<'EOF_UPD_LOCAL'
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::MinimalSteps "true";
EOF_UPD_LOCAL

  systemctl restart unattended-upgrades || true
}

configure_swapfile() {
  if ! str_true "${ENABLE_SWAPFILE}"; then
    return
  fi

  if swapon --show | grep -q '^'; then
    warn "Swap already exists, skipping"
    return
  fi

  log "Creating swapfile ${SWAPFILE_SIZE_GB}G"
  fallocate -l "${SWAPFILE_SIZE_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1G count="${SWAPFILE_SIZE_GB}" status=progress
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile

  if ! grep -q '^/swapfile ' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  echo 'vm.swappiness=10' > /etc/sysctl.d/99-swappiness.conf
  sysctl vm.swappiness=10
}

configure_sysctl() {
  log "Applying base sysctl hardening"

  cat > /etc/sysctl.d/99-bootstrap-hardening.conf <<'EOF_SYSCTL'
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
EOF_SYSCTL

  sysctl --system >/dev/null
}

install_docker() {
  if ! str_true "${ENABLE_DOCKER}"; then
    warn "Docker disabled by config"
    return
  fi

  log "Installing Docker"
  apt_remove docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  # shellcheck disable=SC1091
  . /etc/os-release

  cat > /etc/apt/sources.list.d/docker.sources <<EOF_DOCKER
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF_DOCKER

  apt_update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable docker
  systemctl restart docker
  usermod -aG docker "${ADMIN_USER}" || true
}

configure_shell_helpers() {
  log "Installing shell aliases"

  cat > /etc/profile.d/99-bootstrap-aliases.sh <<'EOF_ALIASES'
alias ll='ls -lah --color=auto'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias dfh='df -h'
alias duh='du -h --max-depth=1'
alias ports='ss -tulpn'
alias myip='curl -4 ifconfig.me ; echo'
EOF_ALIASES

  chmod 644 /etc/profile.d/99-bootstrap-aliases.sh
}

final_report() {
  echo
  echo "=============================================="
  echo "Bootstrap finished"
  echo "Config file:   ${CONFIG_FILE}"
  echo "User:          ${ADMIN_USER}"
  echo "SSH port:      ${SSH_PORT}"
  echo "Timezone:      ${TIMEZONE}"
  echo "Hostname:      ${SET_HOSTNAME:-<unchanged>}"
  echo "Docker:        ${ENABLE_DOCKER}"
  echo "UFW:           ${ENABLE_UFW}"
  echo "Fail2ban:      ${ENABLE_FAIL2BAN}"
  echo "Auto updates:  ${ENABLE_UNATTENDED_UPGRADES}"
  echo "Swapfile:      ${ENABLE_SWAPFILE}"
  echo "=============================================="
  echo
  echo "Before closing this session, test a fresh SSH login."
}

main() {
  require_root
  apt_update_upgrade
  set_timezone
  set_hostname_if_needed
  ensure_admin_user
  configure_ssh
  configure_sysctl
  configure_ufw
  configure_fail2ban
  configure_unattended_upgrades
  configure_swapfile
  install_docker
  configure_shell_helpers
  final_report
}

main "$@"