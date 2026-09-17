#!/usr/bin/env bash
set -Eeuo pipefail

readonly CORE_REPOSITORY="Kimoko/homelab-bootstrap"
readonly CORE_INSTALLER_URL="https://raw.githubusercontent.com/${CORE_REPOSITORY}/main/install.sh"

token_file="${GITHUB_TOKEN_FILE:-}"
token_file_owned="false"
curl_config=""
core_installer=""

die() { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }
log() { printf '\n\033[1;32m[INFO]\033[0m %s\n' "$*"; }

cleanup() {
  local exit_code=$?
  trap - EXIT
  [[ -z "${curl_config}" ]] || rm -f -- "${curl_config}"
  [[ -z "${core_installer}" ]] || rm -f -- "${core_installer}"
  if [[ "${token_file_owned}" == "true" && -n "${token_file}" ]]; then rm -f -- "${token_file}"; fi
  exit "${exit_code}"
}
trap cleanup EXIT

[[ ${EUID} -eq 0 ]] || die "Run through sudo: curl .../install.sh | sudo bash"
command -v curl >/dev/null 2>&1 || die "curl is required. Install curl and ca-certificates first."
[[ -r /dev/tty && -w /dev/tty ]] || die "An interactive terminal is required to request the GitHub token."

prepare_token() {
  local token=""
  if [[ -n "${token_file}" ]]; then
    [[ -f "${token_file}" && -r "${token_file}" ]] || die "Token file is not readable: ${token_file}"
    token="$(tr -d '\r\n' <"${token_file}")"
  else
    read -r -s -p "Fine-grained GitHub token (Contents: read for ${CORE_REPOSITORY}): " token </dev/tty
    printf '\n' >/dev/tty
    token_file="$(mktemp)"
    token_file_owned="true"
    chmod 0600 "${token_file}"
    printf '%s' "${token}" >"${token_file}"
  fi
  [[ -n "${token}" ]] || die "GitHub token is empty."
  [[ "${token}" =~ ^[A-Za-z0-9_]+$ ]] || die "GitHub token contains unexpected characters."
  curl_config="$(mktemp)"
  chmod 0600 "${curl_config}"
  printf 'header = "Authorization: Bearer %s"\n' "${token}" >"${curl_config}"
  unset token
}

download_core_installer() {
  core_installer="$(mktemp)"
  log "Downloading the private bootstrap entrypoint"
  curl --config "${curl_config}" --fail --silent --show-error --location \
    --retry 3 --retry-all-errors --output "${core_installer}" "${CORE_INSTALLER_URL}"
  [[ -s "${core_installer}" ]] || die "Downloaded bootstrap entrypoint is empty."
  bash -n "${core_installer}" || die "Downloaded bootstrap entrypoint failed syntax validation."
  chmod 0700 "${core_installer}"
}

main() {
  prepare_token
  download_core_installer
  log "Starting ${CORE_REPOSITORY}"
  GITHUB_TOKEN_FILE="${token_file}" bash "${core_installer}" "$@"
}

main "$@"

