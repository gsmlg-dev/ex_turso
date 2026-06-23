#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${E2E_DIR}/.." && pwd)"

. "${SCRIPT_DIR}/lib.sh"

export MIX_ENV="${MIX_ENV:-test}"
export EX_TURSO_PATH="${EX_TURSO_PATH:-${REPO_ROOT}}"

align_rust_toolchain

cd "${E2E_DIR}"
mix deps.get

if [[ "${EX_TURSO_INCLUDE_CLOUD:-false}" == "true" ]]; then
  mix test "$@"
else
  mix test --exclude cloud "$@"
fi
