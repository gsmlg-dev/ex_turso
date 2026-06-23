#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <version> [mix test args...]" >&2
  exit 64
fi

VERSION="$1"
shift

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
E2E_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd -- "${E2E_DIR}/.." && pwd)"
ARTIFACT_DIR="${EX_TURSO_RELEASE_DIR:-${REPO_ROOT}/release-artifacts}"

if [[ -z "${EX_TURSO_PATH:-}" ]]; then
  mkdir -p "${ARTIFACT_DIR}"
  TARBALL="${ARTIFACT_DIR}/ex_turso-${VERSION}-source.tar.gz"

  if [[ ! -f "${TARBALL}" ]]; then
    gh release download "v${VERSION}" \
      --pattern "ex_turso-${VERSION}-source.tar.gz" \
      --dir "${ARTIFACT_DIR}"
  fi

  rm -rf "${ARTIFACT_DIR}/ex_turso-${VERSION}"
  tar -xzf "${TARBALL}" -C "${ARTIFACT_DIR}"
  export EX_TURSO_PATH="${ARTIFACT_DIR}/ex_turso-${VERSION}"
fi

"${SCRIPT_DIR}/run-local.sh" "$@"
