#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROLE="${1:-}"

if [[ -z "${ROLE}" ]]; then
  echo "Usage: bash roles/install-role.sh <role-name>"
  exit 1
fi

ROLE_SCRIPT="${SCRIPT_DIR}/${ROLE}.sh"

if [[ ! -f "${ROLE_SCRIPT}" ]]; then
  echo "Role not found: ${ROLE_SCRIPT}"
  exit 1
fi

bash "${ROLE_SCRIPT}"
