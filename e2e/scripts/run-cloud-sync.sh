#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${TURSO_E2E_DATABASE_URL:-}" ]]; then
  echo "TURSO_E2E_DATABASE_URL is required" >&2
  exit 64
fi

if [[ -z "${TURSO_E2E_AUTH_TOKEN:-}" ]]; then
  echo "TURSO_E2E_AUTH_TOKEN is required" >&2
  exit 64
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${E2E_DIR}/.." && pwd)"

. "${SCRIPT_DIR}/lib.sh"

export MIX_ENV="${MIX_ENV:-test}"
export EX_TURSO_PATH="${EX_TURSO_PATH:-${REPO_ROOT}}"
export EX_TURSO_INCLUDE_CLOUD=true

align_rust_toolchain

cd "${E2E_DIR}"
mix deps.get
mix test --only cloud "$@"
