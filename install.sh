#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_REPOSITORY="Kimoko/bootstrap_pub"
readonly DEFAULT_REF="main"
readonly DEFAULT_INSTALL_DIR="/opt/homelab-bootstrap"
readonly DEFAULT_CONFIG_DIR="/etc/homelab-bootstrap"

repository="${HOMELAB_REPOSITORY:-${DEFAULT_REPOSITORY}}"
ref="${HOMELAB_REF:-${DEFAULT_REF}}"
install_dir="${HOMELAB_INSTALL_DIR:-${DEFAULT_INSTALL_DIR}}"
config_dir="${HOMELAB_CONFIG_DIR:-${DEFAULT_CONFIG_DIR}}"
role=""
assume_yes="false"
configure_only="false"
non_interactive="false"
config_mode=""

work_dir=""
staged_dir=""
backup_dir=""

log() { printf '\n\033[1;32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\n\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die() { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: sudo bash install.sh [options]

Options:
  --repo OWNER/REPO      Public GitHub repository (default: Kimoko/bootstrap_pub)
  --ref REF              Branch, tag, or commit SHA (default: main)
  --role NAME            Run roles/NAME.sh after the base bootstrap
  --config PATH          Persistent bootstrap config path
  --config-mode MODE     First-run config mode: wizard or editor
  --yes                   Skip the final confirmation
  --non-interactive       Fail instead of prompting for missing settings
  --configure-only        Prepare/update the config without changing the system
  -h, --help              Show this help

Environment equivalents:
  HOMELAB_REPOSITORY, HOMELAB_REF, HOMELAB_INSTALL_DIR,
  HOMELAB_CONFIG_DIR
EOF
}

cleanup() {
  local exit_code=$?
  trap - EXIT
  [[ -z "${work_dir}" ]] || rm -rf -- "${work_dir}"
  if (( exit_code != 0 )) && [[ -n "${staged_dir}" && -d "${staged_dir}" ]]; then
    rm -rf -- "${staged_dir}"
  fi
  exit "${exit_code}"
}
trap cleanup EXIT

while (($#)); do
  case "$1" in
    --repo) repository="${2:-}"; shift 2 ;;
    --ref) ref="${2:-}"; shift 2 ;;
    --role) role="${2:-}"; shift 2 ;;
    --config) config_file="${2:-}"; shift 2 ;;
    --config-mode) config_mode="${2:-}"; shift 2 ;;
    --yes) assume_yes="true"; shift ;;
    --non-interactive) non_interactive="true"; shift ;;
    --configure-only) configure_only="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ ${EUID} -eq 0 ]] || die "Run this installer as root (sudo)."
[[ "${repository}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Invalid repository: ${repository}"
[[ "${ref}" =~ ^[A-Za-z0-9_./-]+$ ]] || die "Invalid ref: ${ref}"
[[ -z "${role}" || "${role}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "Invalid role: ${role}"
[[ -z "${config_mode}" || "${config_mode}" == "wizard" || "${config_mode}" == "editor" ]] || die "Config mode must be wizard or editor."
[[ "${install_dir}" == /opt/* ]] || die "Install directory must be below /opt."
[[ "${config_dir}" == /etc/* ]] || die "Config directory must be below /etc."

config_file="${config_file:-${config_dir}/bootstrap.env}"
[[ "${config_file}" == "${config_dir}"/* ]] || die "Config must be stored below ${config_dir}."

if [[ ! -r /etc/os-release ]]; then die "Cannot identify the operating system."; fi
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "Only Ubuntu is currently supported (detected: ${ID:-unknown})."

install_prerequisites() {
  local missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v tar >/dev/null 2>&1 || missing+=(tar)
  [[ -r /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
  if ((${#missing[@]})); then
    log "Installing download prerequisites: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=60 -o Acquire::Retries=5 update
    apt-get -o DPkg::Lock::Timeout=60 -o Acquire::Retries=5 install -y --no-install-recommends "${missing[@]}"
  fi
}

download_repository() {
  local archive archive_url extracted
  work_dir="$(mktemp -d)"
  archive="${work_dir}/repository.tar.gz"
  archive_url="https://api.github.com/repos/${repository}/tarball/${ref}"
  log "Downloading ${repository}@${ref}"
  curl --fail --silent --show-error --location \
    --retry 3 --retry-all-errors --output "${archive}" "${archive_url}"
  tar -tzf "${archive}" >/dev/null || die "Downloaded archive is invalid."
  if tar -tzf "${archive}" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    die "Downloaded archive contains an unsafe path."
  fi
  mkdir "${work_dir}/source"
  tar -xzf "${archive}" --strip-components=1 -C "${work_dir}/source"
  extracted="${work_dir}/source"
  [[ -f "${extracted}/bootstrap/bootstrap-ubuntu.sh" ]] || die "Archive does not contain the expected bootstrap entrypoint."
  [[ -f "${extracted}/bootstrap/.env.example" ]] || die "Archive does not contain bootstrap/.env.example."
  if [[ -n "${role}" && ! -f "${extracted}/roles/${role}.sh" ]]; then
    die "Role '${role}' does not exist in ${repository}@${ref}."
  fi
}

prompt_value() {
  local variable_name=$1 prompt=$2 default_value=$3 secret=${4:-false} value=""
  if [[ "${non_interactive}" == "true" ]]; then
    printf -v "${variable_name}" '%s' "${default_value}"
    return
  fi
  [[ -r /dev/tty && -w /dev/tty ]] || die "Interactive terminal unavailable; use --non-interactive with a prepared config."
  if [[ "${secret}" == "true" ]]; then
    read -r -s -p "${prompt} [hidden]: " value </dev/tty
    printf '\n' >/dev/tty
  else
    read -r -p "${prompt} [${default_value}]: " value </dev/tty
  fi
  printf -v "${variable_name}" '%s' "${value:-${default_value}}"
}

validate_config() {
  chown root:root "${config_file}"
  chmod 0600 "${config_file}"
  (
    set -Eeuo pipefail
    # shellcheck disable=SC1090
    source "${config_file}"
    [[ "${TIMEZONE:-}" =~ ^[A-Za-z0-9_+.-]+(/[A-Za-z0-9_+.-]+)*$ ]] || die "Invalid TIMEZONE in ${config_file}."
    [[ "${ADMIN_USER:-}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid ADMIN_USER in ${config_file}."
    if [[ ! "${SSH_PORT:-}" =~ ^[0-9]+$ ]] || ((SSH_PORT < 1 || SSH_PORT > 65535)); then
      die "Invalid SSH_PORT in ${config_file}."
    fi
    [[ "${ADMIN_PUBKEY:-}" =~ ^ssh-(ed25519|rsa)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]] || die "A valid ADMIN_PUBKEY is required in ${config_file}."
    [[ "${EXTRA_TCP_PORTS:-}" =~ ^([0-9]+)(,[0-9]+)*$|^$ ]] || die "Invalid EXTRA_TCP_PORTS in ${config_file}."
    [[ "${EXTRA_UDP_PORTS:-}" =~ ^([0-9]+)(,[0-9]+)*$|^$ ]] || die "Invalid EXTRA_UDP_PORTS in ${config_file}."
    local setting value
    for setting in ENABLE_PASSWORDLESS_SUDO ENABLE_UFW ENABLE_FAIL2BAN ENABLE_UNATTENDED_UPGRADES ENABLE_DOCKER ENABLE_SWAPFILE INSTALL_EXTRA_PACKAGES; do
      value="${!setting:-}"
      [[ "${value}" == "true" || "${value}" == "false" ]] || die "${setting} must be true or false in ${config_file}."
    done
  )
  log "Config validation passed: ${config_file}"
}

open_config_editor() {
  local editor="${EDITOR:-}"
  if [[ -n "${editor}" ]]; then
    [[ "${editor}" =~ ^[A-Za-z0-9_./-]+$ ]] || die "EDITOR must be a single executable path without arguments."
    command -v "${editor}" >/dev/null 2>&1 || die "Configured editor was not found: ${editor}"
  elif command -v nano >/dev/null 2>&1; then
    editor="nano"
  elif command -v vi >/dev/null 2>&1; then
    editor="vi"
  else
    die "No console editor found. Install nano/vi or use --config-mode wizard."
  fi
  log "Opening ${config_file} in ${editor}"
  "${editor}" "${config_file}" </dev/tty >/dev/tty
}

write_config() {
  local timezone admin_user admin_pubkey ssh_port extra_tcp enable_docker default_admin="admin"
  install -d -o root -g root -m 0700 "${config_dir}"
  if [[ -f "${config_file}" ]]; then
    log "Using existing config: ${config_file}"
    validate_config
    return
  fi
  [[ "${non_interactive}" != "true" ]] || die "Config is missing in non-interactive mode: ${config_file}"

  log "Creating persistent bootstrap config"
  if [[ -z "${config_mode}" ]]; then
    prompt_value config_mode "Config mode (wizard/editor)" "wizard"
    [[ "${config_mode}" == "wizard" || "${config_mode}" == "editor" ]] || die "Config mode must be wizard or editor."
  fi
  if [[ "${config_mode}" == "editor" ]]; then
    install -o root -g root -m 0600 "${work_dir}/source/bootstrap/.env.example" "${config_file}"
    open_config_editor
    validate_config
    return
  fi

  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then default_admin="${SUDO_USER}"; fi
  prompt_value timezone "Timezone" "Europe/Moscow"
  prompt_value admin_user "Admin user" "${default_admin}"
  prompt_value ssh_port "SSH port" "22"
  prompt_value admin_pubkey "Admin OpenSSH public key" ""
  prompt_value extra_tcp "Additional TCP ports (comma separated)" "80,443"
  prompt_value enable_docker "Install Docker (true/false)" "true"

  [[ "${timezone}" =~ ^[A-Za-z0-9_+.-]+(/[A-Za-z0-9_+.-]+)*$ ]] || die "Invalid timezone."
  [[ "${admin_user}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid admin user."
  if [[ ! "${ssh_port}" =~ ^[0-9]+$ ]] || ((ssh_port < 1 || ssh_port > 65535)); then
    die "Invalid SSH port."
  fi
  [[ "${admin_pubkey}" =~ ^ssh-(ed25519|rsa)[[:space:]][A-Za-z0-9+/=]+([[:space:]].*)?$ ]] || die "A valid OpenSSH public key is required."
  [[ "${extra_tcp}" =~ ^([0-9]+)(,[0-9]+)*$|^$ ]] || die "Invalid TCP port list."
  [[ "${enable_docker}" == "true" || "${enable_docker}" == "false" ]] || die "Docker answer must be true or false."

  umask 077
  {
    printf 'TIMEZONE=%q\n' "${timezone}"
    printf 'SET_HOSTNAME=%q\n' ""
    printf 'ADMIN_USER=%q\n' "${admin_user}"
    printf 'ADMIN_PASSWORD=%q\n' ""
    printf 'ADMIN_PUBKEY=%q\n' "${admin_pubkey}"
    printf 'ENABLE_PASSWORDLESS_SUDO=%q\n' "true"
    printf 'SSH_PORT=%q\n' "${ssh_port}"
    printf 'ENABLE_UFW=%q\n' "true"
    printf 'UFW_DEFAULT_INCOMING=%q\n' "deny"
    printf 'UFW_DEFAULT_OUTGOING=%q\n' "allow"
    printf 'EXTRA_TCP_PORTS=%q\n' "${extra_tcp}"
    printf 'EXTRA_UDP_PORTS=%q\n' ""
    printf 'ENABLE_FAIL2BAN=%q\n' "true"
    printf 'ENABLE_UNATTENDED_UPGRADES=%q\n' "true"
    printf 'ENABLE_DOCKER=%q\n' "${enable_docker}"
    printf 'ENABLE_SWAPFILE=%q\n' "false"
    printf 'SWAPFILE_SIZE_GB=%q\n' "2"
    printf 'INSTALL_EXTRA_PACKAGES=%q\n' "true"
  } >"${config_file}"
  chmod 0600 "${config_file}"
  validate_config
}

confirm_plan() {
  [[ "${assume_yes}" == "true" || "${configure_only}" == "true" ]] && return
  [[ -r /dev/tty && -w /dev/tty ]] || die "Confirmation requires a terminal; pass --yes for unattended execution."
  printf '\nRepository: %s@%s\nInstall:    %s\nConfig:     %s\nRole:       %s\n' \
    "${repository}" "${ref}" "${install_dir}" "${config_file}" "${role:-<none>}" >/dev/tty
  local answer
  read -r -p "Apply this bootstrap to the server? [y/N]: " answer </dev/tty
  [[ "${answer}" == "y" || "${answer}" == "Y" ]] || die "Cancelled."
}

install_source() {
  local parent timestamp
  parent="$(dirname -- "${install_dir}")"
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  install -d -o root -g root -m 0755 "${parent}"
  staged_dir="${install_dir}.staged.${timestamp}.$$"
  cp -a -- "${work_dir}/source" "${staged_dir}"
  chown -R root:root "${staged_dir}"
  if [[ -e "${install_dir}" ]]; then
    backup_dir="${install_dir}.previous.${timestamp}"
    mv -- "${install_dir}" "${backup_dir}"
  fi
  if ! mv -- "${staged_dir}" "${install_dir}"; then
    if [[ -n "${backup_dir}" && -d "${backup_dir}" ]]; then
      mv -- "${backup_dir}" "${install_dir}"
      backup_dir=""
    fi
    die "Could not activate the staged source; previous source restored."
  fi
  staged_dir=""
  printf 'repository=%s\nref=%s\ninstalled_at=%s\n' \
    "${repository}" "${ref}" "$(date --iso-8601=seconds)" >"${install_dir}/.installed-source"
  chmod 0644 "${install_dir}/.installed-source"
}

run_bootstrap() {
  log "Running base bootstrap"
  BOOTSTRAP_ENV="${config_file}" bash "${install_dir}/bootstrap/bootstrap-ubuntu.sh"
  if [[ -n "${role}" ]]; then
    log "Running role: ${role}"
    BOOTSTRAP_ENV="${config_file}" bash "${install_dir}/roles/install-role.sh" "${role}"
  fi
}

main() {
  install_prerequisites
  download_repository
  write_config
  confirm_plan
  if [[ "${configure_only}" == "true" ]]; then
    log "Configuration ready: ${config_file}"
    return
  fi
  install_source
  run_bootstrap
  log "Installation complete. Source: ${install_dir}; config: ${config_file}"
  [[ -z "${backup_dir}" ]] || warn "Previous source was preserved at ${backup_dir}"
}

main

